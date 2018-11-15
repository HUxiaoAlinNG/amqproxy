require "socket"
require "openssl"
require "uri"

module AMQProxy
  class Upstream
    def initialize(@host : String, @port : Int32, @tls : Bool, @log : Logger)
      @socket = uninitialized IO
      @to_client = Channel(AMQ::Protocol::Frame?).new(1)
      @open_channels = Set(UInt16).new
      @unsafe_channels = Set(UInt16).new
    end

    def connect(user : String, password : String, vhost : String)
      tcp_socket = TCPSocket.new(@host, @port)
      tcp_socket.tcp_nodelay = true
      @log.info { "Connected to upstream #{tcp_socket.remote_address}" }
      @socket =
        if @tls
          OpenSSL::SSL::Socket::Client.new(tcp_socket, hostname: @host).tap do |c|
            c.sync_close = true
          end
        else
          tcp_socket
        end
      start(user, password, vhost)
      spawn decode_frames
      self
    rescue ex : IO::EOFError
      @log.error "Failed connecting to upstream #{user}@#{@host}:#{@port}/#{vhost}"
      nil
    end

    # Frames from upstream (to client)
    private def decode_frames
      loop do
        AMQ::Protocol::Frame.from_io(@socket, IO::ByteFormat::NetworkEndian) do |frame|
          case frame
          when AMQ::Protocol::Frame::Method::Channel::OpenOk
            @open_channels.add(frame.channel)
          when AMQ::Protocol::Frame::Method::Channel::CloseOk
            @open_channels.delete(frame.channel)
            @unsafe_channels.delete(frame.channel)
          end
          @to_client.send frame
        end
      end
    rescue ex : Errno | IO::EOFError
      @log.error "Error reading from upstream: #{ex.inspect}"
      close
      @to_client.send nil
    end

    def next_frame
      @to_client.receive_select_action
    end

    SAFE_BASIC_METHODS = [40, 10]

    # Frames from client (to upstream)
    def write(frame : AMQ::Protocol::Frame)
      case frame
      when AMQ::Protocol::Frame::Method::Basic::Get
        unless frame.no_ack
          @unsafe_channels.add(frame.channel)
        end
      when AMQ::Protocol::Frame::Method::Basic
        unless SAFE_BASIC_METHODS.includes? frame.method_id
          @unsafe_channels.add(frame.channel)
        end
      when AMQ::Protocol::Frame::Method::Connection::Close
        @to_client.send AMQ::Protocol::Frame::Method::Connection::CloseOk.new
        return
      when AMQ::Protocol::Frame::Method::Channel::Open
        if @open_channels.includes? frame.channel
          @to_client.send AMQ::Protocol::Frame::Method::Channel::OpenOk.new(frame.channel)
          return
        end
      when AMQ::Protocol::Frame::Method::Channel::Close
        unless @unsafe_channels.includes? frame.channel
          @to_client.send AMQ::Protocol::Frame::Method::Channel::CloseOk.new(frame.channel)
          return
        end
      end
      frame.to_io(@socket, IO::ByteFormat::NetworkEndian)
    rescue ex : Errno | IO::EOFError
      @log.error "Error sending to upstream: #{ex.inspect}"
      @to_client.send nil
    end

    def close
      @socket.close
    end

    def closed?
      @socket.closed?
    end

    def client_disconnected
      @open_channels.each do |ch|
        if @unsafe_channels.includes? ch
          close = AMQ::Protocol::Frame::Method::Channel::Close.new(ch, 200_u16, "", 0_u16, 0_u16)
          close.to_io @socket, IO::ByteFormat::NetworkEndian
          AMQ::Protocol::Frame.from_io(@socket, IO::ByteFormat::NetworkEndian) do |frame|
            case frame
            when AMQ::Protocol::Frame::Method::Channel::CloseOk
              @open_channels.delete(ch)
              @unsafe_channels.delete(ch)
            else
              @log.error "When closing channel, got #{frame.class}, closing"
              @socket.close
            end
          end
        end
      end
    end

    private def start(user, password, vhost)
      @socket.write AMQ::Protocol::PROTOCOL_START_0_9_1.to_slice

      start = AMQ::Protocol::Frame.from_io(@socket, IO::ByteFormat::NetworkEndian) { |f| f.as(AMQ::Protocol::Frame::Method::Connection::Start) }

      props = {
        "product" => "AMQProxy",
        "version" => AMQProxy::VERSION,
        "capabilities" => {
          "authentication_failure_close" => false
        } of String => AMQ::Protocol::Field
      } of String => AMQ::Protocol::Field
      start_ok = AMQ::Protocol::Frame::Method::Connection::StartOk.new(response: "\u0000#{user}\u0000#{password}",
                                                                       client_properties: props, mechanism: "PLAIN", locale: "en_US")
      start_ok.to_io @socket, IO::ByteFormat::NetworkEndian

      tune = AMQ::Protocol::Frame.from_io(@socket, IO::ByteFormat::NetworkEndian) { |f| f.as(AMQ::Protocol::Frame::Method::Connection::Tune) }
      tune_ok = AMQ::Protocol::Frame::Method::Connection::TuneOk.new(tune.channel_max, tune.frame_max, 0_u16)
      tune_ok.to_io @socket, IO::ByteFormat::NetworkEndian

      open = AMQ::Protocol::Frame::Method::Connection::Open.new(vhost: vhost)
      open.to_io @socket, IO::ByteFormat::NetworkEndian

      open_ok = AMQ::Protocol::Frame.from_io(@socket, IO::ByteFormat::NetworkEndian) { |f| f.as(AMQ::Protocol::Frame::Method::Connection::OpenOk) }
    end
  end
end

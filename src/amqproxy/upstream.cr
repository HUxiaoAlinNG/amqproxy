require "socket"
require "openssl"
require "uri"

module AMQProxy
  class Upstream
    def initialize(url)
      uri = URI.parse url
      @tls = (uri.scheme == "amqps").as(Bool)
      @host = uri.host || "localhost"
      @port = uri.port || (@tls ? 5671 : 5672)
      @user = uri.user || "guest"
      @password = uri.password || "guest"
      path = uri.path || ""
      @vhost = path.empty? ? "/" : path[1..-1]

      @socket = uninitialized IO
      @connection_commands = Channel(Nil).new
      @frame_channel = Channel(AMQP::Frame?).new
      @open_channels = Set(UInt16).new
      spawn connect!
    end

    def connect!
      loop do
        tcp_socket = TCPSocket.new(@host, @port)
        @socket = if @tls
                    context = OpenSSL::SSL::Context::Client.new
                    @socket = OpenSSL::SSL::Socket::Client.new(tcp_socket, context)
                  else
                    tcp_socket
                  end
        negotiate_server
        spawn decode_frames
        puts "Connected to upstream #{@host}:#{@port}"
        @connection_commands.receive
      end
    end

    def decode_frames
      loop do
        frame = AMQP::Frame.decode @socket
        case frame
        when AMQP::Channel::OpenOk
          @open_channels.add frame.channel
        when AMQP::Channel::CloseOk
          @open_channels.delete frame.channel
        end
        @frame_channel.send frame
      end
    rescue ex : Errno | IO::EOFError
      puts "proxy decode frame, reconnect: #{ex.inspect}"
      @open_channels.clear
      @frame_channel.receive?
      @connection_commands.send nil
    end

    def next_frame
      @frame_channel.receive_select_action
    end

    def write(bytes : Slice(UInt8))
      @socket.write bytes
    rescue ex : Errno | IO::EOFError
      puts "proxy write bytes, reconnect: #{ex.inspect}"
      @connection_commands.send nil
      Fiber.yield
      write(bytes)
    end

    def closed?
      @socket.closed?
    end

    def close_all_open_channels
      @open_channels.each do |ch|
        puts "Closing client channel #{ch}"
        @socket.write AMQP::Channel::Close.new(ch, 200_u16, "", 0_u16, 0_u16).to_slice
        @frame_channel.receive
      end
    end

    private def negotiate_server
      @socket.write AMQP::PROTOCOL_START

      start = AMQP::Frame.decode @socket
      assert_frame_type start, AMQP::Connection::Start

      start_ok = AMQP::Connection::StartOk.new(response: "\u0000#{@user}\u0000#{@password}")
      @socket.write start_ok.to_slice

      tune = AMQP::Frame.decode @socket
      assert_frame_type tune, AMQP::Connection::Tune

      channel_max = tune.as(AMQP::Connection::Tune).channel_max
      tune_ok = AMQP::Connection::TuneOk.new(heartbeat: 0_u16, channel_max: channel_max)
      @socket.write tune_ok.to_slice

      open = AMQP::Connection::Open.new(vhost: @vhost)
      @socket.write open.to_slice

      open_ok = AMQP::Frame.decode @socket
      assert_frame_type open_ok, AMQP::Connection::OpenOk
    end

    private def assert_frame_type(frame, clz)
      unless frame.class == clz
        raise "Expected frame #{clz} but got: #{frame.inspect}"
      end
    end
  end
end

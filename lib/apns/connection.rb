require 'forwardable'

module APNS
  class Connection
    extend Forwardable
    attr_accessor :ssl, :sock, :last_activity

    def_delegators :@ssl, :closed?, :flush, :read, :connect

    def initialize(host, port, ssl_context)
      @sock         = TCPSocket.new(host, port)
      @ssl          = OpenSSL::SSL::SSLSocket.new(@sock, ssl_context)
      self.connect
      @last_activity = Time.now
    end

    def close
      self.ssl.close
      self.sock.close
    end

    def idle_timeout?
      (Time.now - @last_activity) > idle_timeout_in_sec
    end

    def idle_timeout_in_sec
      ENV['APNS_CONN_IDLE_TIMEOUT'] || 1800
    end

    def write(data)
      @last_activity = Time.now
      self.ssl.write(data)
    end

  end
end
# Copyright (c) 2009 James Pozdena, 2010 Justin.tv
#  
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation
# files (the "Software"), to deal in the Software without
# restriction, including without limitation the rights to use,
# copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following
# conditions:
#  
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#  
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
# OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
require 'socket'
require 'openssl'
require 'json'

module APNS

  class ConnectionError < StandardError; end

  module ConnectionManager
    def open_connection(host, port)
      context      = OpenSSL::SSL::SSLContext.new
      context.cert = OpenSSL::X509::Certificate.new(@pem)
      context.key  = OpenSSL::PKey::RSA.new(@pem, @pass)

      retries = 0
      begin
        return Connection.new(host, port, context)
      rescue SystemCallError
        if (retries += 1) < 5
          sleep 1
          retry
        else
          # Too many retries, re-raise this exception
          raise
        end
      end
    end

    def has_connection?(host, port)
      @connections.has_key?([host,port])
    end

    def create_connection(host, port)
      @connections[[host, port]] = self.open_connection(host, port)
    end

    def find_connection(host, port)
      @connections[[host, port]]
    end

    def remove_connection(host, port)
      if self.has_connection?(host, port)
        conn = @connections.delete([host, port])
        conn.close
      end
    end

    def reconnect_connection(host, port)
      self.remove_connection(host, port)
      self.create_connection(host, port)
    end

    def get_connection(host, port)
      if @cache_connections
        # Create a new connection if we don't have one
        unless self.has_connection?(host, port)
          self.create_connection(host, port)
        end

        conn = self.find_connection(host, port)
        # If we're closed, reconnect
        if conn.idle_timeout? || conn.closed?
          self.reconnect_connection(host, port)
          self.find_connection(host, port)
        else
          return conn
        end
      else
        self.open_connection(host, port)
      end
    end

    def with_connection(host, port, &block)
      retries = 0
      begin
        conn = self.get_connection(host, port)
        yield conn if block_given?

        unless @cache_connections
          conn.close
        end
      rescue Errno::EPIPE, Errno::ETIMEDOUT, OpenSSL::SSL::SSLError, IOError => e
        if (retries += 1) < 5
          self.remove_connection(host, port)
          retry
        else
          # too-many retries, re-raise
          raise ConnectionError, "tried #{retries} times to reconnect but failed: #{e.inspect}"
        end
      end
    end
  end

  class Feedbacker
    include ConnectionManager
    DEFAULT_HOST = 'feedback.sandbox.push.apple.com'
    DEFAULT_PORT = 2196

    attr_accessor :host, :pem, :port, :pass
    def initialize(options={})
      @host = options[:host] || DEFAULT_HOST
      @port = options[:port] || DEFAULT_PORT
      # openssl pkcs12 -in mycert.p12 -out client-cert.pem -nodes -clcerts -passin pass:password
      @pem = options[:pem] # this should be the content of the pem file
      @pass = options[:pass]
    end

    def feedback
      apns_feedback = []
      self.with_feedback_connection do |conn|
        # Read buffers data from the OS, so it's probably not
        # too inefficient to do the small reads
        while data = conn.read(38)
          apns_feedback << self.parse_feedback_tuple(data)
        end
      end
      return apns_feedback
    end

    protected

    # Each tuple is in the following format:
    #
    #              timestamp | token_length (32) | token
    # bytes:  4 (big-endian)      2 (big-endian) | 32
    #
    # timestamp - seconds since the epoch, in UTC
    # token_length - Always 32 for now
    # token - 32 bytes of binary data specifying the device token
    #
    def parse_feedback_tuple(data)
      feedback = data.unpack('N1n1H64')
      {:feedback_at => Time.at(feedback[0]), :length => feedback[1], :device_token => feedback[2] }
    end

    def with_feedback_connection(&block)
      # Explicitly disable the connection cache for feedback
      @cache_connections = false
      self.with_connection(self.host, self.port, &block)
    end
  end

  class Pusher
    include ConnectionManager
    DEFAULT_HOST = 'gateway.sandbox.push.apple.com'
    DEFAULT_PORT = 2195

    attr_accessor :host, :pem, :port, :pass, :cache_connections

    def initialize(options={})
      @host = options[:host] || DEFAULT_HOST
      @port = options[:port] || DEFAULT_PORT
      # openssl pkcs12 -in mycert.p12 -out client-cert.pem -nodes -clcerts -passin pass:password
      @pem = options[:pem] # this should be the content of the pem file
      @pass = options[:pass]
      @cache_connections = options[:cache_connections]
      @connections = {}
    end

    def establish_notification_connection
      if @cache_connections
        begin
          self.get_connection(self.host, self.port)
          return true
        rescue
        end
      end
      return false
    end

    def has_notification_connection?
      return self.has_connection?(self.host, self.port)
    end

    def send_notification(device_token, message)
      self.with_notification_connection do |conn|
        conn.write(self.packaged_notification(device_token, message))
        conn.flush
      end
    end

    def send_notifications(notifications)
      self.with_notification_connection do |conn|
        notifications.each do |n|
          conn.write(self.packaged_notification(n[0], n[1]))
        end
        conn.flush
      end
    end

    protected

    def packaged_notification(device_token, message)
      pt = self.packaged_token(device_token)
      pm = self.packaged_message(message)
      [0, 0, 32, pt, 0, pm.bytes.to_a.size, pm].pack("ccca*cca*")
    end

    def packaged_token(device_token)
      [device_token.gsub(/[\s|<|>]/,'')].pack('H*')
    end

    def packaged_message(message)
      if message.is_a?(Hash)
        message.to_json
      elsif message.is_a?(String)
        '{"aps":{"alert":"'+ message + '"}}'
      else
        raise "Message needs to be either a hash or string"
      end
    end

    def with_notification_connection(&block)
      self.with_connection(self.host, self.port, &block)
    end
  end

end
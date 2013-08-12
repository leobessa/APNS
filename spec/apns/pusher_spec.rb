require File.dirname(__FILE__) + '/../spec_helper'

describe APNS::Pusher do

  let(:pem) { File.read('spec/apns/test.pem') }
  let(:pem_pass) { 'passphrase' }

  let(:options) do
    {
        host: 'www.sample.com',
        pem: pem,
        port: 443,
        pass: pem_pass,
        cache_connections: true
    }
  end
  let(:subject) {  APNS::Pusher.new(options) }
  let(:token) { '7dfbc9b52916a6c3aaf3d9e4e93e6079aee1c9015db464592a4d3734d835e0cb' }
  let(:message) do
    {
      "aps" => {
        "alert" => {
        "body" => "Bob wants to play poker",
        "action-loc-key" => "PLAY"
        },
        "badge" => 5,
      },
      "acme1" => "bar",
      "acme2" => [ "bang",  "whiz" ]
    }
  end

  describe "#new" do
     it "takes options and return an instance of Pusher" do
       subject.should be_an_instance_of(APNS::Pusher)
       subject.host.should == options[:host]
       subject.pem.should == options[:pem]
       subject.port.should == options[:port]
       subject.pass.should == options[:pass]
       subject.cache_connections.should == options[:cache_connections]
     end
  end

  describe "#packaged_notification" do
    it "package the token and the message correctly" do
      packed_notification = subject.send(:packaged_notification,token,message)
      unpacked_elements = packed_notification.unpack('CCCH64CCU*')
      unpacked_elements[0].should == 0
      unpacked_elements[1].should == 0
      unpacked_elements[2].should == 32
      unpacked_elements[3].should == token
      unpacked_elements[4].should == 0
      unpacked_elements[5].should == message.to_json.size
      unpacked_elements[6..-1].pack('C*').force_encoding('utf-8').should == message.to_json
    end
  end

  describe "#send_notification" do
    before(:each) do
      @pusher = APNS::Pusher.new(options)
      @conn = double('connection')
      @pusher.stub(:with_notification_connection).and_yield(@conn)
    end

    it "writes and flushes the packaged notification" do
      @conn.should_receive(:write) do |packaged_notification|
        packed_notification = @pusher.send(:packaged_notification,token,message)
        unpacked_elements = packed_notification.unpack('CCCH64CCU*')
        unpacked_elements[0].should == 0
        unpacked_elements[1].should == 0
        unpacked_elements[2].should == 32
        unpacked_elements[3].should == token
        unpacked_elements[4].should == 0
        unpacked_elements[5].should == message.to_json.size
        unpacked_elements[6..-1].pack('C*').force_encoding('utf-8').should == message.to_json
      end.ordered
      @conn.should_receive(:flush).ordered
      @pusher.send_notification(token, message)
    end
  end

  describe "#send_notifications" do
    before(:each) do
      @pusher = APNS::Pusher.new(options)
      @conn = double('connection')
      @pusher.stub(:with_notification_connection).and_yield(@conn)
    end

    let(:other_token) {token.gsub('a','b')}
    let(:other_message) do
      other_message = message.clone
      other_message['acme1'] = 'foo'
    end

    it "writes each packed notification and flushes the connection once at the end" do
      written_messages = []
      @conn.should_receive(:write).twice do |packaged_notification|
        written_messages << packaged_notification
      end.ordered
      written_messages.each do |packed_notification|
        unpacked_elements = packed_notification.unpack('CCCH64CCU*')
        unpacked_elements[0].should == 0
        unpacked_elements[1].should == 0
        unpacked_elements[2].should == 32
        [token, other_token].should include? unpacked_elements[3]
        unpacked_elements[4].should == 0
        unpacked_elements[5].should == message.to_json.size
        [message, other_message].collect(:to_json).should include? == unpacked_elements[6..-1].pack('C*').force_encoding('utf-8')
      end
      @conn.should_receive(:flush).once.ordered
      @pusher.send_notifications([[token, message], [other_token, other_message]])
    end
  end

  context "when cached connections are enabled" do
    before(:each) do
      @pusher = APNS::Pusher.new(options.merge(cache_connections: true))
      @ssl_conn = double('ssl_connection', :write => true, :close => true, :closed? => false, :flush => true, :connect => true)
      @sock = double('socket', :close => true, :closed? => false)
      OpenSSL::SSL::SSLSocket.stub(:new).and_return(@ssl_conn)
      TCPSocket.stub(:new).and_return(@sock)
    end
    it "uses the same connection multiple times" do
      @pusher.should_receive(:open_connection).once.and_call_original
      3.times { @pusher.send_notification(token, message) }
    end


    context "connections timeout after an idle period" do
      before(:each) do
        @start_time = Time.new
        APNS::Connection.any_instance.stub(:idle_timeout_in_sec).and_return(100)
        Time.stub(:now).and_return(@start_time)
      end

      context "after an short inactivity period" do
        it "uses the same connection" do
          @pusher.should_receive(:open_connection).once.times.and_call_original
          @pusher.send_notification(token, message)
          @pusher.send_notification(token, message)
          Time.stub(:now).and_return(@start_time + 99)
          @pusher.send_notification(token, message)
          @pusher.send_notification(token, message)
        end
      end

      context "after an long inactivity period" do
        it "opens a new connection" do
          @pusher.should_receive(:open_connection).exactly(2).times.and_call_original
          @pusher.send_notification(token, message)
          @pusher.send_notification(token, message)
          Time.stub(:now).and_return(@start_time + 110)
          @pusher.send_notification(token, message)
          Time.stub(:now).and_return(@start_time + 120)
          @pusher.send_notification(token, message)
        end
      end

    end
  end

  context "when cached connections are disabled" do
    before(:each) do
      @pusher = APNS::Pusher.new(options.merge(cache_connections: false))
      @ssl_conn = double('ssl_connection', :write => true, :close => true, :closed? => false, :flush => true, :connect => true)
      @sock = double('socket', :close => true, :closed? => false)
      OpenSSL::SSL::SSLSocket.stub(:new).and_return(@ssl_conn)
      TCPSocket.stub(:new).and_return(@sock)
    end
    it "opens a new connection each time" do
      @pusher.should_receive(:open_connection).exactly(3).times.and_call_original
      3.times { @pusher.send_notification(token, message) }
    end
  end
end
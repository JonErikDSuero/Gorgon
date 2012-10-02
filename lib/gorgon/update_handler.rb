require "socket"
require "yajl"
require "bunny"

class UpdateHandler
  def initialize bunny
    @bunny = bunny
  end

  def handle payload
    reply_exchange_name = payload[:reply_exchange_name]
    reply = {:type => :updating}
    publish_to reply_exchange_name, reply

    # TODO: this is no complete, we have to make sure it installs it in the listener's environment
    pid, stdin, stdout, stderr = Open4::popen4 "gem install gorgon #{payload[:version]}"
    stdin.close

    ignore, status = Process.waitpid2 pid
    exitstatus = status.exitstatus

    output, errors = [stdout, stderr].map { |p| begin p.read ensure p.close end }

    exitstatus = 1
    if exitstatus == 0
      reply = {:type => :update_complete}
      publish_to reply_exchange_name, reply
      @bunny.stop
      exit
    else
      reply = {:type => :update_failed, :stdout => output, :stderr => errors}
      publish_to reply_exchange_name, reply
   end
  end

  private

  # TODO: factors this out to a class
  def publish_to reply_exchange_name, message
    reply_exchange = @bunny.exchange(reply_exchange_name, :auto_delete => true
)
    reply_exchange.publish(Yajl::Encoder.encode(message.merge(:hostname => Socket.gethostname)))
  end
end

require "gorgon/configuration"
require "gorgon/amqp_service"

require "uuidtools"
require "awesome_print"
require "socket"

module WorkUnit
  def self.run_file filename
    require "gorgon/testunit_runner"
    start_t = Time.now
    results = TestRunner.run_file(filename)
    length = Time.now - start_t

    if results.empty?
      {:failures => [], :type => :pass, :time => length}
    else
      {:failures => results, :type => :fail, :time => length}
    end
  end
end

class Worker
  def self.build(job_definition, config_filename)
    config = Configuration.load_configuration_from_file(config_filename)
    connection_config = config[:connection]
    amqp = AmqpService.new connection_config

    callback_framework = CallbackFramework.new(config)

    worker_id = UUIDTools::UUID.timestamp_create.to_s

    new(amqp, job_definition.file_queue_name, job_definition.reply_exchange_name, worker_id, WorkUnit)
  end

  def initialize(params)
    @amqp = params[:amqp]
    @file_queue_name = params[:file_queue_name]
    @reply_exchange_name = params[:reply_exchange_name]
    @worker_id = params[:worker_id]
    @test_runner = params[:test_runner]
  end

  def work
    @amqp.start_worker @file_queue_name, @reply_exchange_name do |queue, exchange|
      while filename = queue.pop
        exchange.publish make_start_message(filename)
        test_results = run_file(filename)
        exchange.publish make_finish_message(filename, test_results)
      end
    end
  end

  def run_file(filename)
    @test_runner.run_file(filename)
  end

  def make_start_message(filename)
    {:action => :start, :hostname => Socket.gethostname, :worker_id => @worker_id, :filename => filename}
  end

  def make_finish_message(filename, results)
    {:action => :finish, :hostname => Socket.gethostname, :worker_id => @worker_id, :filename => filename}.merge(results)
  end
end

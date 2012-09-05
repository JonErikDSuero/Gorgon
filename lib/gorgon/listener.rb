require "gorgon/job_definition"
require "gorgon/configuration"
require "gorgon/worker"

require "yajl"
require "bunny"
require "awesome_print"
require "open4"
require "tmpdir"
require "socket"
require "logger"

class Listener
  include Configuration

  def initialize
    @config_filename = Dir.pwd + "/gorgon_listener.json"
    @available_worker_slots = configuration[:worker_slots]
    initialize_logger

    log "Listener initialized"
    connect
    initialize_personal_job_queue
  end

  def listen
    log "Waiting for jobs..."
    while true
      sleep 10 unless poll
    end
  end

  def connect
    @bunny = Bunny.new(connection_information)
    @bunny.start
  end

  def initialize_personal_job_queue
    @job_queue = @bunny.queue("", :exclusive => true)
    exchange = @bunny.exchange("gorgon.jobs", :type => :fanout)
    @job_queue.bind(exchange)
  end

  def poll
    message = @job_queue.pop
    return false if message[:payload] == :queue_empty

    start_job(message[:payload])
    return true
  end

  def start_job(json_payload)
    log "Job received: #{json_payload}"
    payload = Yajl::Parser.new(:symbolize_keys => true).parse(json_payload)
    @job_definition = JobDefinition.new(payload)
    @reply_exchange = @bunny.exchange(@job_definition.reply_exchange_name)

    copy_source_tree(@job_definition.source_tree_path)
    fork_workers
  end

  def fork_workers
    log "Forking #{configuration[:worker_slots]} worker(s)"

    EventMachine.run do
      configuration[:worker_slots].times do
        @available_worker_slots -= 1
        ENV["GORGON_CONFIG_PATH"] = @config_filename
        ENV["GORGON_WORKER_SLOTS"] = configuration[:worker_slots].to_s
        pid, stdin, stdout, stderr = Open4::popen4 "gorgon spawn_workers"
        stdin.write(@job_definition.to_json)
        stdin.close

        watcher = proc do
          ignore, status = Process.waitpid2 pid
          log "Worker #{pid} finished"
          status
        end

        worker_complete = proc do |status|
          if status.exitstatus != 0
            log_error "Worker #{pid} crashed with exit status #{status.exitstatus}!"
            reply = {:type => :crash,
                     :hostname => Socket.gethostname,
                     :stdout => stdout.read,
                     :stderr => stderr.read}
            @reply_exchange.publish(Yajl::Encoder.encode(reply))
          end
          on_worker_complete
        end
        EventMachine.defer(watcher, worker_complete)
      end
    end
  end

  def on_worker_complete
    @available_worker_slots += 1
    on_current_job_complete if current_job_complete?
  end

  def current_job_complete?
    @available_worker_slots == configuration[:worker_slots]
  end

  def on_current_job_complete
    log "Job '#{@job_definition.inspect}' completed"
    FileUtils::remove_entry_secure(@tempdir)
    EventMachine.stop_event_loop
  end

  def connection_information
    configuration[:connection]
  end

  def configuration
    @configuration ||= load_configuration_from_file("gorgon_listener.json")
  end

private

  def copy_source_tree source_tree_path
    @tempdir = Dir.mktmpdir("gorgon")
    Dir.chdir(@tempdir)
    system("rsync -r --rsh=ssh #{source_tree_path}/* .")

    if ($?.exitstatus == 0)
      log "Syncing completed successfully."
    else
      #TODO handle error:
      # - Discard job
      # - Let the originator know about the error
      # - Wait for the next job
      log_error "Command 'rsync -r --rsh=ssh #{@job_definition.source_tree_path}/* .' failed!"
    end
  end

  def initialize_logger
    return unless configuration[:log_file]
    @logger =
      if configuration[:log_file] == "-"
        Logger.new($stdout)
      else
        Logger.new(configuration[:log_file])
      end
    @logger.datetime_format = "%Y-%m-%d %H:%M:%S "
  end

  def log text
    @logger.info(text) if @logger
  end

  def log_error text
    @logger.error(text) if @logger
  end
end

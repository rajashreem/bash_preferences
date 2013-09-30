#!/usr/bin/env ruby

require "net/http"
require "uri"
require "erb"

class ServiceUtility

  WORKSPACE = "#{Dir.home}/workspace"

  class Service

    attr_accessor :service_name, :port, :environment, :workers

    def initialize(service, options)
      @service_name = service
      options.each_pair do |option_key, option_value|
        send("#{option_key}=",option_value) if respond_to? "#{option_key}="
      end
    end

    def workers
      @workers || 2
    end

    def config
      @config_location ||= generate_config
    end

    def service_location
      "#{ServiceUtility::WORKSPACE}/#{service_name}"
    end

    private

    def generate_config
      template_path = File.read("#{WORKSPACE}/bash_preferences/workspace/unicorn.conf.minimal.rb.erb")
      config_path = "#{service_location}/tmp/unicorn.conf.rb"

      renderer = ERB.new(template_path)
      result = renderer.result(binding)
      File.open(config_path, 'w') { |file| file.write(result) }

      config_path
    end

  end

  class << self

    @@services = {
        "turnstile" => {:port => 3000, :exclude => true},
        "customerservice" => {:port => 3001, :environment => "testintegration"},
        "legacy_service" => {:port => 3002, :exclude => true},
        "catalog_service" => {:port => 3003, :depends_on => "competition_management"},
        "orders_service" => {:port => 3004},
        "payment_service" => {:port => 3005},
        "competition_management" => {:port => 3006},
        "entry_service" => {:port => 3007},
        "communication_service" => {:port => 3008},
        "silverpop_mock" => {:port => 9001, :skip => ["rake db:reset", "rake db:migrate"], :workers => 1}
    }

    def start_all
      kill_services
      clear_redis
      start_services
      start_resque
      sleep 5
      list_running
    end

    def kill_services
      @@services.keys.each do |service|
        kill(service)
      end
    end

    def kill(service=nil)
      service ||= ARGV[1]
      begin
        pid_file = "#{service}/tmp/pids/unicorn.pid"
        pid = (File.read pid_file).to_i
        puts "Terminating #{service}"
        #Process.kill "TERM", pid
        Process.kill 0, pid
        Process.kill "QUIT", pid
      rescue Errno::ENOENT, Errno::ESRCH => e
        puts "#{service} not running..."
      rescue => e
        puts "Unable to terminate #{service}"
        return false
      end
      return true
    end

    def list_running
      alive_services = []
      dead_services = []
      disabled_services = []
      @@services.each_pair do |service, options|
        if options[:exclude]
          disabled_services << service
        else

          begin
            pid_file = "#{service}/tmp/pids/unicorn.pid"
            pid = (File.read pid_file).to_i
            Process.kill 0, pid
            #puts "#{service} is running..."
            alive_services << service
          rescue Errno::ENOENT, Errno::ESRCH => e
            #puts "#{service} does NOT appear to be running..."
            dead_services << service
          end

        end
      end

      puts "Alive Services"
      puts "=============="
      alive_services.each do |alive_service|
        puts alive_service
      end

      puts ""
      puts "=#=#=#=#=#=#=#="
      puts ""

      puts "Dead Services"
      puts "=============="
      dead_services.each do |dead_service|
        puts dead_service
      end

      puts ""
      puts "=#=#=#=#=#=#=#="
      puts ""

      puts "Disabled Services"
      puts "=============="
      disabled_services.each do |disabled_service|
        puts disabled_service
      end

    end

    def start
      service_name = ARGV[1]
      options = @@services[service_name]
      if options.nil?
        puts "#{service_name} is not a valid service"
      elsif options[:exclude]
        puts "#{service_name} is disabled"
      else
        start_service(service_name, options)
      end
    end

    private

    def start_service(service_name, options)

      puts "killing any existing instance first..."

      kill(service_name)

      puts "Starting #{service_name}"
      `cd #{service_name} && gem install unicorn` unless `cd #{service_name} && gem list`.lines.grep(/^unicorn \(.*\)/)

      if `cd #{service_name} && gem list`.lines.grep(/^unicorn \(.*\)/)
        if options[:depends_on].nil?
          boot_service(service_name, options)
        else
          boot_service_after_dependency(service_name)
        end
      else
        puts "Unable to start #{service_name} as unicorn is still not installed"
      end

    end

    def boot_service(service_name, options)
      port = options[:port]
      environment = options[:environment]
      environment ||= "development"

      use_bundled_unicorn = `cd #{service_name} && bundle list`.match("unicorn")

      rake_tasks = ["rake db:migrate", "rake db:reset"]

      cmd = "export RAILS_ENV=#{environment} && cd #{service_name} && bundle install"
      rake_tasks.each do |task|
        cmd << "&& bundle exec #{task}" if options[:skip].nil? || !options[:skip].include?(task)
      end

      service_obj = Service.new(service_name, options)

      cmd << "&& #{use_bundled_unicorn ? "bundle exec" : ""} unicorn_rails -p#{port} -c #{service_obj.config} -E #{environment} -D"

      system cmd
      options[:booted] = true
    end

    def boot_service_after_dependency(service_name, tries = 0)

      service_options = @@services[service_name]
      dependency_name = service_options[:depends_on]
      dependency_options = @@services[dependency_name]

      puts "Waiting to start #{service_name} after #{dependency_name}"
      dependency_port = dependency_options[:port]
      uri = URI.parse("http://localhost:#{dependency_port}")

      begin
        Net::HTTP.get_response(uri)
        boot_service(service_name, service_options)
      rescue Errno::ECONNREFUSED => e
        # only try to start the dependancy if its not already started but only start it once
        start_service(dependency_name, dependency_options) unless dependency_options[:booted]
        sleep(5)
        tries += 1
        if tries < 20
          boot_service_after_dependency(service_name, tries)
        else
          puts "Aborting startup of #{service_name} as #{dependency_name} has not started after #{tries*5} seconds"
        end
      end
    end

    def kill_services_old
      puts "Killing existing unicorn processes"
      system "ps aux | grep 'unicorn' | awk '{print $2}' | xargs kill -9"
    end

    def clear_redis
      puts "Clearing out redis"
      system "redis-cli flushdb"
    end

    def start_services
      @@services.each_pair do |service_name, options|
        start_service(service_name, options) unless options[:exclude]
      end

      puts "Starting silverpop mock"
      system "cd silverpop_mock && bundle install && bundle exec rails s -p9001 &"

    end

    def start_resque_for(service_name)
      puts "Starting resque for #{service_name}"
      system "cd #{service_name} && bundle exec rake resque:work QUEUE=orders_service &"
    end

    def start_resque
      start_resque_for("orders_service")
      start_resque_for("communication_service")
      start_resque_for("competition_management")
    end

  end
end

command = (ARGV[0]).to_sym unless ARGV[0].nil?

if !command.nil? && ServiceUtility.respond_to?(command)
  ServiceUtility.send(command)
else
  puts "Incorrect or no command, available commands are.."

  public_commands = (ServiceUtility.methods - Object.methods)
  public_commands.each do |command|
    puts command
  end
end
#!/usr/bin/env ruby

require "net/http"
require "uri"
require "erb"

class ServiceUtility

  WORKSPACE = "#{Dir.home}/workspace"

  SERVICES = {
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

  class Service

    class << self

      def build(service_name)
        options = ServiceUtility::SERVICES[service_name]
        if options.nil?
          puts "Could not find service definition for #{service_name}"
          false
        else
          Service.new(service_name, options)
        end
      end

    end

    attr_accessor :service_name, :port, :environment, :workers, :exclude, :depends_on, :skip

    alias_method :dependency_name, :depends_on

    def initialize(service, options)
      @exclude = false
      @service_name = service
      options.each_pair do |option_key, option_value|
        send("#{option_key}=", option_value) if respond_to? "#{option_key}="
      end
    end

    def workers
      @workers || 2
    end

    def environment
      @environment || "development"
    end

    def config
      @config_location ||= generate_config
    end

    def kill
      begin
        puts "Terminating #{service_name}"
        #Process.kill "TERM", pid
        Process.kill 0, pid
        Process.kill "QUIT", pid
      rescue Errno::ENOENT, Errno::ESRCH => e
        puts "#{service_name} not running..."
      rescue => e
        puts "Unable to terminate #{service_name}"
        return false
      end
      return true
    end

    def start

      if disabled?
        puts "=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+"
        puts "not starting #{service_name} as it is disabled"
        puts "=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+"
        return false
      end

      puts "killing any existing instance of #{service_name} first..."

      kill

      puts "Starting #{service_name}"
      `cd #{service_location} && gem install unicorn` unless `cd #{service_location} && gem list`.lines.grep(/^unicorn \(.*\)/)

      if `cd #{service_location} && gem list`.lines.grep(/^unicorn \(.*\)/)
        if depends_on.nil?
          boot_service
        else
          boot_service_after_dependency
        end
      else
        puts "+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+"
        puts "Unable to start #{service_name} as unicorn is still not installed"
        puts "+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+"
      end

    end

    def disabled?
      exclude
    end

    def running?
      begin
        Process.kill 0, pid
        true
      rescue Errno::ENOENT, Errno::ESRCH => e
        false
      end
    end

    def booted?
      @booted
    end

    def tail
      exec "tail -f #{log_file}"
    end

    private

    def boot_service
      use_bundled_unicorn = `cd #{service_location} && bundle list`.match("unicorn")

      rake_tasks = ["rake db:migrate", "rake db:reset"]

      cmd = "export RAILS_ENV=#{environment} && cd #{service_location} && bundle install"
      rake_tasks.each do |task|
        cmd << "&& bundle exec #{task}" if skip.nil? || !skip.include?(task)
      end


      cmd << "&& #{use_bundled_unicorn ? "bundle exec" : ""} unicorn_rails -p#{port} -c #{config} -E #{environment} -D"

      puts "booting #{service_name} with command..."
      puts cmd
      puts "=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+="

      @booted = system(cmd)

    end

    def boot_service_after_dependency

      puts "Waiting to start #{service_name} after #{dependency_name}"

      dependency_service = ServiceUtility.services[dependency_name]
      dependency_port = dependency_service.port

      uri = URI.parse("http://localhost:#{dependency_port}")

      tries = 0

      begin
        Net::HTTP.get_response(uri)
        boot_service
      rescue Errno::ECONNREFUSED => e
        # only try to start the dependancy if its not already started but only start it once
        dependency_service.start unless dependency_service.booted?

        sleep(5)
        tries += 1
        if tries < 20
          retry
        else
          puts "Aborting startup of #{service_name} as #{dependency_name} has not started after #{tries*5} seconds"
        end
      end

    end

    def generate_config
      template_path = File.read("#{WORKSPACE}/bash_preferences/workspace/unicorn.conf.minimal.rb.erb")
      config_path = "#{service_location}/tmp/unicorn.conf.rb"

      renderer = ERB.new(template_path)
      result = renderer.result(binding)
      tmp_dir = File.dirname(config_path)
      Dir.mkdir(tmp_dir) unless File.directory?(tmp_dir)
      File.open(config_path, 'w') { |file| file.write(result) }

      config_path
    end

    def service_location
      "#{ServiceUtility::WORKSPACE}/#{service_name}"
    end

    def log_file
      "#{service_location}/log/#{environment}.log"
    end

    def tmp
      "#{service_location}/tmp"
    end

    def pid_file
      "#{tmp}/pids/unicorn.pid"
    end

    def pid
      (File.read pid_file).to_i
    end

  end

  class << self


    def start_all
      create_sftp_user
      kill_all
      clear_redis
      start_services
      start_resque
      sleep 5
      check_all
      list_running
    end

    def kill_all
      services.values.each do |service|
        service.kill
      end
    end

    def kill(service_name=nil)
      service_name ||= ARGV[1]
      services[service_name].kill
    end

    def list_running
      alive_services = []
      dead_services = []
      disabled_services = []

      services.values.each do |service|
        if service.disabled?
          disabled_services << service
        elsif service.running?
          alive_services << service
        else
          dead_services << service
        end
      end

      puts "Alive Services"
      puts "=============="
      alive_services.each do |alive_service|
        puts alive_service.service_name
      end

      puts ""
      puts "=#=#=#=#=#=#=#="
      puts ""

      puts "Dead Services"
      puts "=============="
      dead_services.each do |dead_service|
        puts dead_service.service_name
      end

      puts ""
      puts "=#=#=#=#=#=#=#="
      puts ""

      puts "Disabled Services"
      puts "=============="
      disabled_services.each do |disabled_service|
        puts disabled_service.service_name
      end

    end

    def start
      service_name = ARGV[1]
      service = services[service_name]
      if service.nil?
        puts "#{service_name} is not a valid service"
      else
        service.start
      end
    end

    def tail(service_name=nil)
      service_name ||= ARGV[1]
      service = services[service_name]
      if service.nil?
        puts "#{service_name} not valid"
      else
        service.tail
      end
    end

    def services
      @services ||= SERVICES.keys.inject({}) do |services_collection, service_name|
        services_collection[service_name] = Service.build(service_name)
        services_collection
      end
    end

    protected

    private

    def check_all
      services.values.each do |service|
        service.start unless service.running?
      end
    end

    def create_sftp_user(user_name="vagrant", password=nil)
      password ||= user_name
      puts "=+=+=+=+=+=+=+=+=+=+=+=+=+=+="
      if  RbConfig::CONFIG['host_os'].include? "linux"
        if File.read("/etc/passwd").match("^#{user_name}:").nil?
          puts "creating #{user_name} user"
          new_home_dir = "/home/#{user_name}"
          system "sudo useradd -d #{new_home_dir} -m #{user_name} && echo #{user_name}:#{password} | sudo chpasswd"
        else
          puts "#{user_name} user already exists not creating"
        end
        puts "=+=+=+=+=+=+=+=+=+=+=+=+=+=+="


        puts "=+=+=+=+=+=+=+=+=+=+=+=+=+=+="
        puts "Ensuring Turnstile and tmp directories exists"
        puts "=+=+=+=+=+=+=+=+=+=+=+=+=+=+="
        home_dir = `echo ~#{user_name}`.chomp

        ["#{home_dir}/Turnstile", "#{home_dir}/tmp"].each do |dir|
          system "sudo mkdir -p #{dir} " unless File.directory?(dir)
        end

      else
        puts "=+=+=+=+=+=+=+=+=+=+=+=+=+=+="
        puts "Cant create user #{user_name} on host OS"
        puts "=+=+=+=+=+=+=+=+=+=+=+=+=+=+="
        sleep 20
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
      services.values.each do |service|
        service.start
      end

    end

    def start_resque_for(service_name)
      puts "Starting resque for #{service_name}"
      system "cd #{WORKSPACE}/#{service_name} && bundle exec rake resque:work QUEUE=orders_service &"
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

  public_commands = (ServiceUtility.methods - Object.methods - [:services])
  public_commands.each do |command|
    puts command
  end
end
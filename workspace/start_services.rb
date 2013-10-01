#!/usr/bin/env ruby

require "net/http"
require "uri"
require "erb"

class ServiceUtility

  WORKSPACE = "#{Dir.home}/workspace"

  class Service

    class << self

      def build(service_name)
        options = ServiceUtility.class_variable_get("@@services")[service_name]
        if options.nil?
          puts "Could not find service definition for #{service_name}"
          false
        else
          Service.new(service_name, options)
        end
      end

    end

    attr_accessor :service_name, :port, :environment, :workers, :exclude

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

    private

    def generate_config
      template_path = File.read("#{WORKSPACE}/bash_preferences/workspace/unicorn.conf.minimal.rb.erb")
      config_path = "#{service_location}/tmp/unicorn.conf.rb"

      renderer = ERB.new(template_path)
      result = renderer.result(binding)
      File.open(config_path, 'w') { |file| file.write(result) }

      config_path
    end

    def service_location
      "#{ServiceUtility::WORKSPACE}/#{service_name}"
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
      create_sftp_user
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

    def kill(service_name=nil)
      service_name ||= ARGV[1]
      Service.build(service_name).kill
    end

    def list_running
      alive_services = []
      dead_services = []
      disabled_services = []

      services.each do |service|
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

        ["#{home_dir}/Turnstile","#{home_dir}/tmp"].each do | dir |
          system "sudo mkdir -p #{dir} " unless File.directory?(dir)
        end

      else
        puts "=+=+=+=+=+=+=+=+=+=+=+=+=+=+="
        puts "Cant create user #{user_name} on host OS"
        puts "=+=+=+=+=+=+=+=+=+=+=+=+=+=+="
        sleep 20
      end
    end

    def services
      @@services.keys.collect { |service_name| Service.build(service_name) }
    end

    def start_service(service_name, options)

      puts "killing any existing instance first..."

      kill(service_name)

      puts "Starting #{service_name}"
      `cd #{WORKSPACE}/#{service_name} && gem install unicorn` unless `cd #{WORKSPACE}/#{service_name} && gem list`.lines.grep(/^unicorn \(.*\)/)

      if `cd #{WORKSPACE}/#{service_name} && gem list`.lines.grep(/^unicorn \(.*\)/)
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

      use_bundled_unicorn = `cd #{WORKSPACE}/#{service_name} && bundle list`.match("unicorn")

      rake_tasks = ["rake db:migrate", "rake db:reset"]

      cmd = "export RAILS_ENV=#{environment} && cd #{WORKSPACE}/#{service_name} && bundle install"
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

  public_commands = (ServiceUtility.methods - Object.methods)
  public_commands.each do |command|
    puts command
  end
end
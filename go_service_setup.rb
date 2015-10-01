require 'sys/proctable'

SOURCE_CODE_DIR = File.join(ENV['HOME'], 'go', 'src', 'github.com')

# copy the environment config for a given service from Cucumber's /support directory into the Go directory for that service
# @param service [String]
def copy_project_env_config(service)
  file_path = File.join('.', 'features', 'support', "#{service}_env.sh")
  service_dir = File.join(SOURCE_CODE_DIR, service)
  if File.exists?(service_dir)
    FileUtils.copy(file_path, service_dir)
  else
    #bail out of test if service directory not found:
    Cucumber.wants_to_quit = true
  end
end

# if the myWireFormat directory doesn't exist or if it is empty, grab the C proto template from the submodule
# @param directory [String] where the protoc file lives
def check_protoc(directory='./myWireFormat')
  if !Dir.exist?(directory) || (Dir.entries(directory) - %w{ . ..  }).empty?
    system "git submodule update --init --recursive"
  end
end

# checks that the protoc file and the Go-compiled protobuf file exist, and the Go protobuf is more recent than the protoc template
# If the protoc template has been updated since last compilation, recompile to Go
def check_go_protobuf
  protofile = File.join('.', 'myWireFormat', 'my_wire_format.proto')
  gofile = File.join('.', 'myWireFormat', 'my_wire_format.pb.go')

  unless File.exists?(gofile) && File.mtime(gofile) > File.mtime(protofile)
    system 'protoc --go_out=. ./myWireFormat/*.proto'
  end
end

# compile protoc for Ruby
# @param service [String] name of service to compile Ruby protobuf for
def compile_ruby_protobuf_template(service)
  cuke_home = Dir.pwd
  case service
    when 'go-cart-tests'
      protoc_dir = './myWireFormat'
    else
      protoc_dir = '../../myWireFormat'
  end

  file = File.join(protoc_dir, 'my_wire_format.rb')
  #delete old copy if it's there:
  if File.exist?(file)
    File.delete(file)
  end

  #change working directory and recreate the ruby protobuf from the protoc template:
  Dir.chdir(protoc_dir)
  template = './my_wire_format.proto'
  system "protoc --ruby_out=. #{template}"  # <-- syntax for google-protobuf gem
  Dir.chdir(cuke_home)
  require File.join(protoc_dir, 'my_wire_format.rb')
end

# find which git branch your service is currently on
# @return branch name [String]
def check_git_branch_name
  IO.popen("git rev-parse --abbrev-ref HEAD") {|query| query.read.chomp}
end

# start up a Go service from local Go path, ensuring that the protobufs are set up and writing the service logs to a file
# @param service [String]
def start_go_service_locally(service)
  cuke_home = Dir.pwd
  service_dir = File.join(SOURCE_CODE_DIR, service)
  Dir.chdir(service_dir)

  #make sure the C protoc file is present and the Go compilation is newer (and thus assume it's compiled from the protoc)
  check_protoc
  check_go_protobuf

  branch = check_git_branch_name
  unless branch == 'master'
    puts "\nALERT! Your version of #{service} is not on master branch but on branch: #{branch}.  Adjust if necessary\n\n"
  end

  #build the service:
  system "godep go build"

  #source the env file, start the service and pipe its logs to cucumber's support/logs directory:
  Thread.new do
    system ". #{service_dir}/#{service}_env.sh && #{service_dir}/./#{service} > #{cuke_home}/features/support/logs/#{service}_cucumber.log"
  end

  #go home:
  Dir.chdir(cuke_home)
end

# wrapper method for starting Go services locally
# @param services [Array] of service names
def set_up_go_services(services)
  services.each do |service|
    copy_project_env_config(service)
    start_go_service_locally(service)
  end
end

# get the process id from the service name so that you can kill it when the testrun is complete
# @param service [String]
# @return pid
def get_pid(service)
  ProcTable.ps { |p|
    if p.comm.start_with?(service)
      return p.pid.to_s
    end
  }
end

# call the system to kill the service
# @param service [String]
def kill_service(service)
  pid = get_pid(service)
  system "kill #{pid}"
end

# delete the custom environment config added in previous test steps
# @param service [String]
def delete_service_config(service)
  service_dir = File.join(SOURCE_CODE_DIR, service)
  FileUtils.remove("#{service_dir}/#{service}_env.sh")
end

# delete the Go binary created at the beginning of the test run
# @param service [String]
def delete_service_binary(service)
  service_dir = File.join(SOURCE_CODE_DIR, service)
  FileUtils.remove("#{service_dir}/#{service}")
end

# wrapper method for stopping a locally-running service and deleting the environment config and compiled binary
# @param services [Array]
def tear_down_services(services)
  services.each do |service|
    kill_service(service)
    delete_service_config(service)
    delete_service_binary(service)
  end
end

#remove service logs from previous test run at start of current test run:
def test_log_cleanup
  file_path = File.join('.', 'features', 'support', 'logs')
  Dir.glob("#{file_path}/*cucumber.log").each { |file| FileUtils.remove(file) }
end

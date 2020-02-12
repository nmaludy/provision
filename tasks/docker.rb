#!/usr/bin/env ruby
require 'json'
require 'yaml'
require 'puppet_litmus'
require_relative '../lib/task_helper'

def install_ssh_components(platform, version, container)
  case platform
  when 'debian'
    warn '!!! Disabling ESM security updates for ubuntu - no access without privilege !!!'
    run_local_command("docker exec #{container} rm -f /etc/apt/sources.list.d/ubuntu-esm-infra-trusty.list")
    run_local_command("docker exec #{container} apt-get update")
    run_local_command("docker exec #{container} apt-get install -y openssh-server openssh-client")
  when %r{fedora}
    run_local_command("docker exec #{container} dnf clean all")
    run_local_command("docker exec #{container} dnf install -y sudo openssh-server openssh-clients")
    run_local_command("docker exec #{container} ssh-keygen -A")
  when 'redhat'
    if version == '6'
      # sometimes the redhat 6 variant containers like to eat their rpmdb, leading to
      # issues with "rpmdb: unable to join the environment" errors
      # This "fix" is from https://www.srv24x7.com/criticalyum-main-error-rpmdb-open-failed/
      run_local_command("docker exec #{container} bash -exc \"rm -f /var/lib/rpm/__db*; "\
        'db_verify /var/lib/rpm/Packages; '\
        'rpm --rebuilddb; '\
        'yum clean all; '\
        'yum install -y sudo openssh-server openssh-clients"')
    else
      run_local_command("docker exec #{container} yum install -y sudo openssh-server openssh-clients")
    end
    ssh_folder = run_local_command("docker exec #{container} ls /etc/ssh/")
    run_local_command("docker exec #{container} ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key -N \"\"") unless ssh_folder =~ %r{ssh_host_rsa_key}
    run_local_command("docker exec #{container} ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key -N \"\"") unless ssh_folder =~ %r{ssh_host_dsa_key}
  when 'sles'
    run_local_command("docker exec #{container} zypper -n in openssh")
    run_local_command("docker exec #{container} ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key")
    run_local_command("docker exec #{container} ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key")
    run_local_command("docker exec #{container} sed -ri \"s/^#?UsePAM .*/UsePAM no/\" /etc/ssh/sshd_config")
  when 'archlinux'
    run_local_command("docker exec #{container} pacman --noconfirm -Sy archlinux-keyring")
    run_local_command("docker exec #{container} pacman --noconfirm -Syu")
    run_local_command("docker exec #{container} pacman -S --noconfirm openssh")
    run_local_command("docker exec #{container} ssh-keygen -A")
    run_local_command("docker exec #{container} sed -ri \"s/^#?UsePAM .*/UsePAM no/\" /etc/ssh/sshd_config")
    run_local_command("docker exec #{container} systemctl enable sshd")
  else
    raise "platform #{platform} not yet supported on docker"
  end

  # Make sshd directory, set root password
  run_local_command("docker exec #{container} mkdir -p /var/run/sshd")
  run_local_command("docker exec #{container} bash -c \"echo root:root | /usr/sbin/chpasswd\"")
end

def fix_ssh(platform, container)
  run_local_command("docker exec #{container} sed -ri \"s/^#?PermitRootLogin .*/PermitRootLogin yes/\" /etc/ssh/sshd_config")
  run_local_command("docker exec #{container} sed -ri \"s/^#?PasswordAuthentication .*/PasswordAuthentication yes/\" /etc/ssh/sshd_config")
  run_local_command("docker exec #{container} sed -ri \"s/^#?UseDNS .*/UseDNS no/\" /etc/ssh/sshd_config")
  run_local_command("docker exec #{container} sed -e \"/HostKey.*ssh_host_e.*_key/ s/^#*/#/\" -ri /etc/ssh/sshd_config")
  case platform
  when 'debian'
    run_local_command("docker exec #{container} service ssh restart")
  when 'redhat'
    if container !~ %r{7|8}
      run_local_command("docker exec #{container} service sshd restart")
    else
      run_local_command("docker exec -d #{container} /usr/sbin/sshd -D")
    end
  else
    raise "platform #{platform} not yet supported on docker"
  end
end

def match_os_family(str)
  case str
  when %r{debian}, %r{ubuntu}, %r{cumulus}
    'debian'
  when %r{fedora}
    'fedora'
  when %r{centos}, %r{^el-}, %r{eos}, %r{oracle}, %r{redhat}, %r{scientific}
    'redhat'
  when %r{opensuse}, %r{sles}
    'sles'
  when %r{archlinux}
    'archlinux'
  else
    raise "platform #{platform} not yet supported on docker"
  end
end

def determine_platform_version(container, tag)
  # first try to extract OS family from the container
  platform = match_os_family(container)
  # if the container didn't have it, maybe the tag does?
  platform ||= match_os_family(tag)
  # no smart way to extract the version right now
  [platform, tag]
end

def provision(docker_platform, inventory_location, vars)
  include PuppetLitmus::InventoryManipulation
  inventory_full_path = File.join(inventory_location, 'inventory.yaml')
  inventory_hash = get_inventory_hash(inventory_full_path)
  warn '!!! Using private port forwarding!!!'
  container, tag = docker_platform.split(':')
  container = container.sub(%r{/}, '_')
  platform, version = determine_platform_version(container, tag)
  front_facing_port = 2222
  full_container_name = "#{platform}_#{version}-#{front_facing_port}"
  (front_facing_port..2230).each do |i|
    front_facing_port = i
    full_container_name = "#{platform}_#{version}-#{front_facing_port}"
    ports = "#{front_facing_port}->22"
    list_command = 'docker container ls -a'
    stdout, _stderr, _status = Open3.capture3(list_command)
    break unless stdout.include?(ports)
    raise 'All front facing ports are in use.' if front_facing_port == 2230
  end
  deb_family_systemd_volume = if (docker_platform =~ %r{debian|ubuntu}) && (docker_platform !~ %r{debian8|ubuntu14})
                                '--volume /sys/fs/cgroup:/sys/fs/cgroup:ro'
                              else
                                ''
                              end
  creation_command = "docker run -d -it #{deb_family_systemd_volume} --privileged -p #{front_facing_port}:22 --name #{full_container_name} #{docker_platform}"
  run_local_command(creation_command)
  install_ssh_components(platform, version, full_container_name)
  fix_ssh(platform, full_container_name)
  hostname = 'localhost'
  node = { 'uri' => "#{hostname}:#{front_facing_port}",
           'config' => { 'transport' => 'ssh',
                         'ssh' => { 'user' => 'root', 'password' => 'root', 'port' => front_facing_port, 'host-key-check' => false } },
           'facts' => { 'provisioner' => 'docker', 'container_name' => full_container_name, 'platform' => docker_platform } }
  unless vars.nil?
    var_hash = YAML.safe_load(vars)
    node['vars'] = var_hash
  end
  group_name = 'ssh_nodes'
  add_node_to_group(inventory_hash, node, group_name)
  File.open(inventory_full_path, 'w') { |f| f.write inventory_hash.to_yaml }
  { status: 'ok', node_name: "#{hostname}:#{front_facing_port}", node: node }
end

def tear_down(node_name, inventory_location)
  include PuppetLitmus::InventoryManipulation
  inventory_full_path = File.join(inventory_location, 'inventory.yaml')
  raise "Unable to find '#{inventory_full_path}'" unless File.file?(inventory_full_path)
  inventory_hash = inventory_hash_from_inventory_file(inventory_full_path)
  node_facts = facts_from_node(inventory_hash, node_name)
  remove_docker = "docker rm -f #{node_facts['container_name']}"
  run_local_command(remove_docker)
  remove_node(inventory_hash, node_name)
  puts "Removed #{node_name}"
  File.open(inventory_full_path, 'w') { |f| f.write inventory_hash.to_yaml }
  { status: 'ok' }
end

params = JSON.parse(STDIN.read)
platform = params['platform']
action = params['action']
node_name = params['node_name']
inventory_location = sanitise_inventory_location(params['inventory'])
vars = params['vars']
raise 'specify a node_name when tearing down' if action == 'tear_down' && node_name.nil?
raise 'specify a platform when provisioning' if action == 'provision' && platform.nil?
unless node_name.nil? ^ platform.nil?
  case action
  when 'tear_down'
    raise 'specify only a node_name, not platform, when tearing down'
  when 'provision'
    raise 'specify only a platform, not node_name, when provisioning'
  else
    raise 'specify only one of: node_name, platform'
  end
end

begin
  result = provision(platform, inventory_location, vars) if action == 'provision'
  result = tear_down(node_name, inventory_location) if action == 'tear_down'
  puts result.to_json
  exit 0
rescue => e
  puts({ _error: { kind: 'provision/docker_failure', msg: e.message, backtrace: e.backtrace } }.to_json)
  exit 1
end

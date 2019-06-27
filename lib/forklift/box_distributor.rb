module Forklift
  class BoxDistributor

    VAGRANTFILE_API_VERSION = '2'.freeze

    def initialize(boxes)
      @ansible_groups = {}
      @boxes = boxes
      @boxes = @boxes.keys.sort.each_with_object({}) do |key, hash|
        hash[key] = @boxes[key]
        hash
      end
      @settings = settings
    end

    def settings
      overrides = {}
      settings_file = "#{File.dirname(__FILE__)}/../../settings.yaml"
      default_settings = {
        'memory' => 4608,
        'cpus' => 2,
        'sync_type' => 'rsync',
        'cachier' => {
          'mount_options' => ['rw', 'vers=3', 'tcp', 'nolock']
        }
      }

      overrides = YAML.load_file(settings_file) if File.exist?(settings_file)

      @settings ||= default_settings.merge(overrides)
    end

    def distribute
      Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
        configure_vagrant_hostmanager(config)
        configure_vagrant_cachier(config)

        @boxes.each do |_name, box|
          define_vm config, box
        end

        config.vm.provider :libvirt do |domain|
          domain.memory = @settings['memory']
          domain.cpus   = @settings['cpus']
        end

        config.vm.provider :virtualbox do |domain|
          domain.memory = @settings['memory']
          domain.cpus   = @settings['cpus']
          domain.customize ['modifyvm', :id, '--natdnsproxy1', 'off']
          domain.customize ['modifyvm', :id, '--natdnshostresolver1', 'off']
        end
      end
    end

    def define_vm(config, box = {})
      config.vm.define box.fetch('name'), primary: box.fetch('default', false) do |machine|
        machine.vm.box = box.fetch('box_name')
        machine.vm.box_check_update = true
        config.ssh.insert_key = false
        machine.vm.box_url = box.fetch('box_url') if box.key?('box_url')

        machine.vm.hostname = if box.fetch('hostname', false)
                                box.fetch('hostname')
                              else
                                "#{box.fetch('name').to_s.tr('.', '-')}.example.com"
                              end

        networks = configure_networks(box.fetch('networks', []))
        configure_shell(machine, box)
        configure_ansible(machine, box['ansible'], box['name'])
        configure_libvirt(machine, box, networks)
        configure_virtualbox(machine, box)
        configure_rackspace(machine, box)

        yield machine if block_given?
      end
    end

    def configure_vagrant_hostmanager(config)
      return unless Vagrant.has_plugin?('vagrant-hostmanager')
      config.hostmanager.enabled = true
      config.hostmanager.manage_host = true
      config.hostmanager.manage_guest = true
      config.hostmanager.include_offline = true
    end

    def configure_vagrant_cachier(config)
      return unless Vagrant.has_plugin?('vagrant-cachier')
      config.cache.scope = :box
      config.cache.synced_folder_opts = {
        type: :nfs,
        mount_options: @settings['cachier']['mount_options']
      }
    end

    def configure_networks(networks)
      return [] if networks.empty?
      networks.map do |network|
        symbolized_options = network['options'].inject({}) { |memo, (k, v)| memo.update(k.to_sym => v) }
        network.update('options' => symbolized_options)
      end
    end

    def configure_ansible(machine, ansible, box_name)
      return unless ansible
      unless @ansible_groups[ansible['group'].to_s]
        @ansible_groups[ansible['group'].to_s] = []
      end

      @ansible_groups[ansible['group'].to_s] << box_name

      if ansible.key?('server')
        @ansible_groups["server-#{box_name}"] = ansible['server']
      end

      return unless (playbooks = ansible['playbook'])

      [playbooks].flatten.each_with_index do |playbook, index|
        args = ["main#{index}", type: 'ansible']
        machine.vm.provision(*args) do |ansible_provisioner|
          ansible_provisioner.playbook = playbook
          ansible_provisioner.extra_vars = ansible['variables']
          ansible_provisioner.groups = @ansible_groups
        end
      end
    end

    def configure_shell(machine, box)
      return unless box.key?('shell') && !box['shell'].nil?
      machine.vm.provision :shell do |shell|
        shell.inline = box.fetch('shell')
        shell.privileged = false if box.key?('privileged')
      end
    end

    def configure_libvirt(machine, box, networks = [])
      machine.vm.provider :libvirt do |p, override|
        override.vm.box_url = box.fetch('libvirt') if box.fetch('libvirt', false)
        override.vm.synced_folder '.', '/vagrant', type: @settings['sync_type'], rsync__args: ['--max-size=100m']

        if box.fetch('bridged', false)
          override.vm.network :public_network, :dev => box.fetch('bridged'), :mode => 'bridge'
        end
        networks.each do |network|
          override.vm.network network['type'], network['options']
        end
        p.cpus = box.fetch('cpus') if box.fetch('cpus', false)
        p.memory = box.fetch('memory') if box.fetch('memory', false)
        p.machine_virtual_size = box.fetch('disk_size') if box.fetch('disk_size', false)
      end
    end

    def configure_virtualbox(machine, box)
      machine.vm.provider :virtualbox do |p, override|
        override.vm.box_url = box.fetch('virtualbox') if box.fetch('virtualbox', false)
        p.cpus = box.fetch('cpus') if box.fetch('cpus', false)
        p.memory = box.fetch('memory') if box.fetch('memory', false)

        if box.fetch('name').to_s.include?('devel')
          override.vm.network :forwarded_port, guest: 3000, host: 3330
          override.vm.network :forwarded_port, guest: 443, host: 4430
        else
          override.vm.network :forwarded_port, guest: 80, host: 8080
          override.vm.network :forwarded_port, guest: 443, host: 4433
        end
      end
    end

    def configure_rackspace(machine, box)
      return unless box.fetch('image_name', false)
      machine.vm.provider :rackspace do |p, override|
        override.vm.box  = 'dummy'
        p.server_name    = machine.vm.hostname
        p.flavor         = /4GB/
        p.image          = box.fetch('image_name')
        override.ssh.pty = true if box.fetch('pty')
      end
    end

  end
end

require 'json'
require 'erb'
require 'yaml'

module Forklift
  class BoxFactory

    attr_accessor :boxes

    def initialize
      @boxes = {}
    end

    def add_boxes(box_file, version_file)
      config = load_box_file(box_file)
      return @boxes unless config

      versions = YAML.load_file(version_file)

      if config.key?('boxes')
        process_versions(config, versions)
        process_boxes(config['boxes'])
      else
        process_boxes(config)
      end

      @boxes
    end

    private

    def load_box_file(file)
      file = File.read(file)
      YAML.load(ERB.new(file).result)
    end

    def process_boxes(boxes)
      boxes.each do |name, box|
        box['name'] = name
        box = layer_base_box(box)

        if @boxes[name]
          @boxes[name].merge!(box)
        else
          @boxes[name] = box
        end
      end

      @boxes
    end

    def process_versions(config, versions)
      versions['installers'].each do |version|
        version['boxes'].each do |base_box|
          scenarios = config['boxes'][base_box]['scenarios'] || []
          scenarios.each do |scenario|
            installer_box = build_box(config['boxes'][base_box], 'server', "playbooks/#{scenario}.yml", version)
            config['boxes']["#{base_box}-#{scenario}-#{version[scenario]}"] = installer_box
          end

          next unless scenarios.include?('katello')

          foreman_proxy_box = build_box(config['boxes'][base_box], 'foreman-proxy-content',
                                        'playbooks/foreman_proxy_content.yml', version)
          foreman_proxy_box['ansible']['server'] = "#{base_box}-katello-#{version['katello']}"
          config['boxes']["#{base_box}-foreman-proxy-#{version['katello']}"] = foreman_proxy_box
        end
      end
    end

    def layer_base_box(box)
      return box unless (base_box = find_base_box(box['box']))
      base_box.merge(box)
    end

    def find_base_box(name)
      return false if name.nil?
      @boxes[name]
    end

    def build_box(base_box, group, playbook, version)
      box = JSON.parse(JSON.dump(base_box))

      variables = {}
      variables.merge!(box['ansible']['vars']) if box['ansible'] && box['ansible']['vars']
      variables.merge!(
        'foreman_repositories_version' => version['foreman'],
        'katello_repositories_version' => version['katello'],
        'puppet_repositories_version'  => version['puppet']
      )

      box['ansible'] = {
        'playbook' => playbook,
        'group'    => group,
        'variables' => variables
      }

      box
    end

  end
end

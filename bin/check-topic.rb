#! /usr/bin/env ruby
#
# check-topic
#
# DESCRIPTION:
#   This plugin checks topic properties.
#
# OUTPUT:
#   plain-text
#
# PLATFORMS:
#   Linux
#
# DEPENDENCIES:
#   gem: sensu-plugin
#   gem: zookeeper
#
# USAGE:
#   ./check-topic
#
# NOTES:
#
# LICENSE:
#   Olivier Bazoud
#   Released under the same terms as Sensu (the MIT license); see LICENSE
#   for details.
#

require 'sensu-plugin/check/cli'
require 'json'
require 'zookeeper'

class TopicsCheck < Sensu::Plugin::Check::CLI
  option :zookeeper,
         description: 'ZooKeeper connect string (host:port,..)',
         short:       '-z ZOOKEEPER',
         long:        '--zookeeper ZOOKEEPER',
         default:     'localhost:2181',
         required:    true

  option :name,
         description: 'Topic name',
         short: '-n TOPIC_NAME',
         long: '--name TOPIC_NAME',
         required:    true

  option :partitions,
         description: 'Partitions',
         short: '-p PARTITIONS_COUNT',
         long: '--partitions TOPIC_NAME',
         proc: proc(&:to_i)

  option :replication_factor,
         description: 'Replication factor',
         short: '-r REPLICATION_FACTOR',
         long: '--replication-factor REPLICATION_FACTOR',
         proc: proc(&:to_i)

  option :configs,
         description: 'Topic configurations',
         short: '-c CONFIG',
         long: '--configs CONFIG',
         proc: proc { |a| JSON.parse(a) }

  option :replicas,
         description: 'Check replicats',
         short: '-a',
         long: '--replicas',
         default: false,
         boolean: false

  option :leader,
         description: 'Check leader',
         short: '-l',
         long: '--leader',
         default: false,
         boolean: false

  def run
    z = Zookeeper.new(config[:zookeeper])

    topics = z.get_children(path: '/brokers/topics')[:children].sort

    critical "Topic '#{config[:name]}' not found" unless topics.include? config[:name]

    if config.key?(:partitions) || config.key?(:replication_factor)
      brokers = z.get_children(path: '/brokers/ids')[:children].map(&:to_i)
      partitions_data = z.get(path: "/brokers/topics/#{config[:name]}")[:data]
      partitions = JSON.parse(partitions_data)['partitions']

      critical "Topic '#{config[:name]}' has #{partitions.size} partitions, expecting #{config[:partitions]}" if config.key?(:partitions) && partitions.size != config[:partitions]

      if config.key?(:replication_factor)
        min = partitions.min_by { |_, b| b.size }[1].length
        max = partitions.max_by { |_, b| b.size }[1].length
        critical "Topic '#{config[:name]}' RF is between #{min} and #{max}, expecting #{config[:replication_factor]}" if config[:replication_factor] != min || min != max
      end

      if config[:replicas]
        partitions.each do |num, replica|
          critical "Topic '#{config[:name]}', partition #{num}: unknown replica #{replica - brokers}" unless (replica - brokers).empty?
        end
      end

      if config[:leader]
        partitions.each do |num, replica|
          state_json = z.get(path: "/brokers/topics/#{config[:name]}/partitions/#{num}/state")[:data]
          state = JSON.parse(state_json)
          critical "Topic '#{config[:name]}', partition #{num}: unknown leader #{state['leader']}" unless brokers.include? state['leader']
          critical "Topic '#{config[:name]}', partition #{num}: preferred replica is not #{replica[0]}" unless replica[0] == state['leader']
          critical "Topic '#{config[:name]}', partition #{num}: isr is not consistent" unless (replica - state['isr']).empty? && (state['isr'] - replica).empty?
          critical "Topic '#{config[:name]}', partition #{num}: unknown isr #{state['isr'] - brokers}" unless (state['isr'] - brokers).empty?
        end
      end

      if config.key?(:configs)
        config_data = z.get(path: "/config/topics/#{config[:name]}")[:data]
        configs = JSON.parse(config_data)['config']
        config[:configs].each do |k, v|
          critical "Topic '#{config[:name]}': config #{k} = #{v}, expecting #{configs[k]}" if !configs.key?(k) || configs[k].to_s != v.to_s
        end
      end

    end
    ok
  rescue => e
    puts "Error: #{e.backtrace}"
    critical "Error: #{e}"
  end
end

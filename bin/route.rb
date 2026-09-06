#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative '../lib/provider_loader'
require_relative '../lib/provider_state'
require_relative '../lib/quantum_client'
require_relative '../lib/router'
require_relative '../lib/report_builder'

def usage_and_exit
  warn 'Использование: ruby bin/route.rb <operations_queue.json> [decisions_name] [report_name]'
  warn 'Пример:        ruby bin/route.rb data/operations_queue_10.json routing_decisions_10 routing_report_10'
  exit 1
end

usage_and_exit if ARGV.empty?

queue_path = ARGV[0]
decisions_name = ARGV[1] || 'routing_decisions'
report_name = ARGV[2] || 'routing_report'

repo_root = File.expand_path('..', __dir__)
providers_path = File.join(repo_root, 'data', 'providers.json')
config_path = File.join(repo_root, 'config', 'routing_config.json')

loaded = ProviderLoader.load(providers_path: providers_path, config_path: config_path)
providers = loaded[:providers]
config = loaded[:config]

queue = JSON.parse(File.read(queue_path))
queue = queue.sort_by { |op| op['created_at'] }

state = ProviderState.new(providers)
quantum_client = QuantumClient.new
router = Router.new(
  providers: providers,
  state: state,
  quantum_client: quantum_client,
  strategies: config['strategies'],
  rng_seed: config['simulation_seed'] || 'quantum-router-2026',
  quantum_opts: {
    p: config.dig('quantum', 'p') || 2,
    shots: config.dig('quantum', 'shots') || 4096,
    restarts: config.dig('quantum', 'restarts') || 5,
    backend: config.dig('quantum', 'backend') || 'simulator'
  }
)

decisions = queue.map { |op| router.route(op) }

period = loaded[:snapshot_at].to_s.split('T').first
report = ReportBuilder.build(decisions: decisions, providers: providers, state: state, period: period)

decisions_path = File.join(repo_root, "#{decisions_name}.json")
report_path = File.join(repo_root, "#{report_name}.json")

File.write(decisions_path, JSON.pretty_generate(decisions))
File.write(report_path, JSON.pretty_generate(report))

fallback_quantum = decisions.count do |d|
  d['attempts'].any? { |a| a['decision'] == 'selected' && a['reason'] == 'quantum_optimal' }
end
fallback_self = decisions.count { |d| d['selected_provider'] == 'spacepayments' }

puts "OK: #{decisions.size} операций обработано"
puts "-> #{decisions_path}"
puts "-> #{report_path}"
puts "решений через квантовый ранжировщик: #{fallback_quantum}"
puts "fallback на self-provider (spacepayments): #{fallback_self}"

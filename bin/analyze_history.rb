#!/usr/bin/env ruby
# frozen_string_literal: true

# Калибровка по data/operations_history.csv: фактическая доля по
# количеству/объёму vs traffic_percentage/volume_share_pct, и реальный
# approval-rate vs "текущий" conversion_24h из providers.json.
#
# Ничего не меняет в роутинге -- отдельный отчёт (data-in -> JSON-out).

require 'csv'
require 'json'

repo_root = File.expand_path('..', __dir__)
history_path = File.join(repo_root, 'data', 'operations_history.csv')
providers_path = File.join(repo_root, 'data', 'providers.json')

rows = CSV.read(history_path, headers: true)
providers = JSON.parse(File.read(providers_path))['providers']
conversion_by_name = providers.to_h { |p| [p['payment_system'], p['conversion_24h'].to_f] }
traffic_target_by_name = providers.to_h { |p| [p['payment_system'], p['traffic_percentage'].to_f] }

total_count = rows.size
total_volume = rows.sum { |r| r['amount'].to_f }

stats = Hash.new { |h, k| h[k] = { count: 0, approved: 0, volume: 0.0, latency_sum: 0.0 } }

rows.each do |r|
  name = r['payment_system']
  amount = r['amount'].to_f
  s = stats[name]
  s[:count] += 1
  s[:volume] += amount
  s[:latency_sum] += r['latency_sec'].to_f
  s[:approved] += 1 if r['status'] == 'approved'
end

report = {}
stats.each do |name, s|
  approval_rate = s[:count].zero? ? 0.0 : (s[:approved].to_f / s[:count] * 100).round(1)
  stated_conversion = ((conversion_by_name[name] || 0.0) * 100).round(1)
  report[name] = {
    'count' => s[:count],
    'count_share_pct' => (s[:count].to_f / total_count * 100).round(1),
    'traffic_target_pct' => traffic_target_by_name[name],
    'volume_share_pct' => (s[:volume] / total_volume * 100).round(1),
    'avg_latency_sec' => (s[:latency_sum] / s[:count]).round(1),
    'historical_approval_rate_pct' => approval_rate,
    'stated_conversion_24h_pct' => stated_conversion,
    'conversion_gap_pct' => (stated_conversion - approval_rate).round(1)
  }
end

findings = []
report.each do |name, r|
  if (r['count_share_pct'] - r['traffic_target_pct']).abs > 10
    findings << "#{name}: историческая доля по count #{r['count_share_pct']}% заметно отклоняется " \
                "от traffic_percentage #{r['traffic_target_pct']}%"
  end
  if r['conversion_gap_pct'].abs > 15
    findings << "#{name}: conversion_24h из providers.json (#{r['stated_conversion_24h_pct']}%) " \
                "расходится с фактическим approval-rate за историю (#{r['historical_approval_rate_pct']}%) " \
                "на #{r['conversion_gap_pct'].abs}пп -- в soft-goal 'conversion' стоит либо доверять этой " \
                "метрике осторожнее, либо пересчитать её из истории вместо снимка providers.json"
  end
end

output = { 'source' => 'data/operations_history.csv', 'total_operations' => total_count,
           'by_provider' => report, 'findings' => findings }

out_path = File.join(repo_root, 'historical_analysis.json')
File.write(out_path, JSON.pretty_generate(output))

puts "OK: #{total_count} исторических операций проанализировано -> #{out_path}"
findings.each { |f| puts "- #{f}" }

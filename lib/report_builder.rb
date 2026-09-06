# frozen_string_literal: true

# Собирает routing_report_*.json: распределение vs цель, skip-причины,
# утилизация лимитов, рекомендации по настройке.
module ReportBuilder
  def self.build(decisions:, providers:, state:, period:)
    total = decisions.size
    counts = Hash.new(0)
    decisions.each { |d| counts[d['selected_provider']] += 1 if d['selected_provider'] }

    distribution = {}
    providers.each do |p|
      name = p['payment_system']
      count = counts[name].to_i
      next if name == 'spacepayments' && count.zero?

      distribution[name] = {
        'count' => count,
        'share_pct' => total.zero? ? 0.0 : (count.to_f / total * 100).round(1),
        'target_pct' => p['traffic_percentage'].to_f
      }
    end

    skip_reasons = Hash.new(0)
    decisions.each do |d|
      d['attempts'].each { |a| skip_reasons[a['reason']] += 1 if a['decision'] == 'skipped' }
    end

    utilization = {}
    providers.each do |p|
      name = p['payment_system']
      limit = p['daily_amount_limit']
      next unless limit

      used = state.daily_approved_amount(name)
      utilization[name] = {
        'used' => used.round,
        'limit' => limit,
        'utilization_pct' => (used / limit.to_f * 100).round(1)
      }
    end

    {
      'period' => period,
      'total_operations' => total,
      'distribution' => distribution,
      'skip_reasons' => skip_reasons,
      'projected_daily_utilization' => utilization,
      'recommendations' => recommendations(distribution, utilization)
    }
  end

  def self.recommendations(distribution, utilization)
    recs = []

    distribution.each do |name, d|
      diff = d['share_pct'] - d['target_pct']
      if diff > 10
        recs << "#{name}: фактическая доля #{d['share_pct']}% заметно выше целевой " \
                "#{d['target_pct']}% - снизить приоритет или traffic_percentage"
      elsif diff < -10
        recs << "#{name}: фактическая доля #{d['share_pct']}% заметно ниже целевой " \
                "#{d['target_pct']}% - повысить приоритет или ослабить лимиты конкурентов"
      end
    end

    utilization.each do |name, u|
      if u['utilization_pct'] > 80
        recs << "#{name} близок к дневному лимиту (#{u['utilization_pct']}%) - " \
                'снизить traffic_percentage или увеличить daily_amount_limit'
      end
    end

    recs
  end
end

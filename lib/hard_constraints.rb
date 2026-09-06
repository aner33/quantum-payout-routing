# frozen_string_literal: true

require 'time'

# Проверки 1-8 совпадают 1-в-1 с eligible_providers из validate_10.rb, чтобы
# selected_provider всегда проходил официальную проверку. Rate-limit (9) --
# наша доп. проверка сверх их скрипта, делает eligible-список строгим
# подмножеством их -- к расхождению не приводит, только к более
# консервативному выбору.
module HardConstraints
  Result = Struct.new(:provider, :eligible, :reason, :details, keyword_init: true)

  def self.evaluate(operation, providers, state)
    results = providers.map { |p| assess(operation, p, state) }
    eligible = results.select(&:eligible)
    skipped = results.reject(&:eligible)
    [eligible, skipped]
  end

  def self.assess(operation, provider, state)
    amount = operation['amount']
    bank = operation['bank']

    if provider['status'] != 'active'
      return skip(provider, 'provider_inactive', "status=#{provider['status']}")
    end

    traffic_pct = provider['traffic_percentage'].to_f
    if traffic_pct.zero? && provider['payment_system'] != 'spacepayments'
      return skip(provider, 'zero_traffic_target', 'traffic_percentage=0, провайдер отключён от роутинга')
    end

    if provider['limit_amount_min'] && amount < provider['limit_amount_min']
      return skip(provider, 'amount_below_minimum', "#{amount} < limit_amount_min #{provider['limit_amount_min']}")
    end

    if provider['limit_amount_max'] && amount > provider['limit_amount_max']
      return skip(provider, 'amount_exceeds_limit', "#{amount} > limit_amount_max #{provider['limit_amount_max']}")
    end

    daily_used = state.daily_approved_amount(provider['payment_system'])
    if provider['daily_amount_limit'] && (daily_used + amount) > provider['daily_amount_limit']
      return skip(provider, 'daily_limit_exceeded',
                  "#{daily_used.to_i}+#{amount} > daily_amount_limit #{provider['daily_amount_limit']}")
    end

    ip_count = state.in_progress_count(provider['payment_system'])
    if provider['in_progress_count_limit'] && (ip_count + 1) > provider['in_progress_count_limit']
      return skip(provider, 'in_progress_count_exceeded',
                  "#{ip_count}+1 > in_progress_count_limit #{provider['in_progress_count_limit']}")
    end

    ip_amount = state.in_progress_amount(provider['payment_system'])
    if provider['in_progress_amount_limit'] && (ip_amount + amount) > provider['in_progress_amount_limit']
      return skip(provider, 'in_progress_amount_exceeded',
                  "#{ip_amount.to_i}+#{amount} > in_progress_amount_limit #{provider['in_progress_amount_limit']}")
    end

    if provider['available_requisites'].to_i.zero?
      return skip(provider, 'no_requisites', 'available_requisites=0')
    end

    if provider['provider_margin_pct'].to_f > provider['merchant_margin_pct'].to_f && !provider['allow_negative_agreement']
      return skip(provider, 'margin_negative',
                  "provider_margin_pct #{provider['provider_margin_pct']} > merchant_margin_pct #{provider['merchant_margin_pct']}")
    end

    banks = provider['banks'] || []
    if banks.any?
      excluded = provider['exclude_banks'] ? banks.include?(bank) : !banks.include?(bank)
      if excluded
        return skip(provider, 'bank_not_in_list',
                    "bank=#{bank} banks=#{banks} exclude_banks=#{provider['exclude_banks']}")
      end
    end

    rpm_limit = provider['requests_per_minute_limit']
    if rpm_limit
      current_rpm = state.requests_last_minute(provider['payment_system'], operation['created_at'])
      if (current_rpm + 1) > rpm_limit
        return skip(provider, 'rate_limited', "#{current_rpm}+1 > requests_per_minute_limit #{rpm_limit}")
      end
    end

    Result.new(provider: provider['payment_system'], eligible: true, reason: nil, details: nil)
  end

  def self.skip(provider, reason, details)
    Result.new(provider: provider['payment_system'], eligible: false, reason: reason, details: details)
  end
end

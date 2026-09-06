# frozen_string_literal: true

require 'time'

# Состояние провайдера в рамках одного прогона -- daily/in-progress/rate
# limits и soft-goals доли считаются от него, а не от статичного снимка.
class ProviderState
  def initialize(providers)
    @daily_approved_amount = {}
    @in_progress_count = {}
    @in_progress_amount = {}
    @approved_count = {}
    @approved_volume = {}
    @request_timestamps = Hash.new { |h, k| h[k] = [] }

    providers.each do |p|
      name = p['payment_system']
      @daily_approved_amount[name] = p['daily_approved_amount'].to_f
      @in_progress_count[name] = p['in_progress_count'].to_i
      @in_progress_amount[name] = p['in_progress_amount'].to_f
      @approved_count[name] = 0
      @approved_volume[name] = 0.0
    end
  end

  def daily_approved_amount(provider)
    @daily_approved_amount.fetch(provider, 0.0)
  end

  def in_progress_count(provider)
    @in_progress_count.fetch(provider, 0)
  end

  def in_progress_amount(provider)
    @in_progress_amount.fetch(provider, 0.0)
  end

  def approved_count(provider)
    @approved_count.fetch(provider, 0)
  end

  def approved_volume(provider)
    @approved_volume.fetch(provider, 0.0)
  end

  def total_approved_count
    @approved_count.values.sum
  end

  def total_approved_volume
    @approved_volume.values.sum
  end

  def requests_last_minute(provider, created_at)
    now = Time.parse(created_at)
    window_start = now - 60
    @request_timestamps[provider].select! { |t| t > window_start }
    @request_timestamps[provider].size
  end

  # Занимает in-progress слот и окно rate-limit при отправке попытки.
  def register_attempt(provider, created_at, amount)
    @request_timestamps[provider] << Time.parse(created_at)
    @in_progress_count[provider] = in_progress_count(provider) + 1
    @in_progress_amount[provider] = in_progress_amount(provider) + amount
  end

  # Освобождает in-progress слот; если approved -- пишет в дневные тоталы.
  def register_result(provider, amount, approved:)
    @in_progress_count[provider] = [in_progress_count(provider) - 1, 0].max
    @in_progress_amount[provider] = [in_progress_amount(provider) - amount, 0.0].max

    return unless approved

    @daily_approved_amount[provider] = daily_approved_amount(provider) + amount
    @approved_count[provider] = approved_count(provider) + 1
    @approved_volume[provider] = approved_volume(provider) + amount
  end
end

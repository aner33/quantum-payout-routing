# frozen_string_literal: true

require 'json'

# Домешивает в providers.json поля, которых там нет (requests_per_minute_limit,
# volume_share_pct, daily_turnover_min/max) из config -- оригинал не трогаем.
module ProviderLoader
  def self.load(providers_path:, config_path:)
    raw = JSON.parse(File.read(providers_path))
    config = JSON.parse(File.read(config_path))
    overrides = config['provider_overrides'] || {}

    providers = raw['providers'].map do |p|
      extra = overrides[p['payment_system']] || {}
      extra = extra.reject { |k, _v| k.start_with?('_') }
      p.merge(extra) { |_key, original, _override| original }
    end

    {
      snapshot_at: raw['snapshot_at'],
      gateway: raw['gateway'],
      merchant: raw['merchant'],
      providers: providers,
      config: config
    }
  end
end

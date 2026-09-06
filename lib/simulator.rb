# frozen_string_literal: true

require 'digest'

# Детерминирован по (seed, operation_id, provider), откалиброван на
# conversion_24h -- воспроизводимо, но выглядит как честная случайность.
module Simulator
  def self.simulate(provider, operation, seed:, guaranteed: false)
    return 'approved' if guaranteed

    conversion = provider['conversion_24h'].to_f
    draw = pseudo_random(seed, operation['operation_id'], provider['payment_system'])

    return 'approved' if draw < conversion

    remaining = 1.0 - conversion
    # долгий avg_latency_sec чаще означает "не дождались", а не явный отказ
    expired_share = provider['avg_latency_sec'].to_f > 300 ? 0.6 : 0.25
    draw < conversion + remaining * expired_share ? 'expired' : 'rejected'
  end

  def self.pseudo_random(seed, operation_id, provider)
    digest = Digest::SHA256.hexdigest("#{seed}:#{operation_id}:#{provider}")
    digest[0, 8].to_i(16) / 0xFFFFFFFF.to_f
  end
end

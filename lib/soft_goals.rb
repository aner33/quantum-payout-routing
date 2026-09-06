# frozen_string_literal: true

# Кто предпочтительнее из прошедших hard-constraints? Нарушение не
# запрещает провайдера, только повышает cost (ниже = лучше) -- этот cost
# и уходит в QUBO-решатель (quantum/quantum_router.py), который не знает
# ничего про стратегии, только "минимизируй число".
#
# Веса и вкл/выкл каждого компонента -- в config/routing_config.json.
module SoftGoals
  def self.cost(provider, operation, state, strategies)
    total = 0.0
    breakdown = {}

    if (s = strategies['traffic_share']) && s['enabled']
      value = traffic_share_deviation(provider, state)
      breakdown['traffic_share'] = value
      total += s['weight'] * value
    end

    if (s = strategies['volume_share']) && s['enabled']
      value = volume_share_deviation(provider, operation, state)
      breakdown['volume_share'] = value
      total += s['weight'] * value
    end

    if (s = strategies['priority_cascade']) && s['enabled']
      value = priority_component(provider)
      breakdown['priority_cascade'] = value
      total += s['weight'] * value
    end

    if (s = strategies['conversion']) && s['enabled']
      value = 1.0 - provider['conversion_24h'].to_f
      breakdown['conversion'] = value
      total += s['weight'] * value
    end

    if (s = strategies['turnover_obligation']) && s['enabled']
      value = turnover_component(provider, state)
      breakdown['turnover_obligation'] = value
      total += s['weight'] * value
    end

    if (s = strategies['amount_fit']) && s['enabled']
      value = amount_fit_component(provider, operation)
      breakdown['amount_fit'] = value
      total += s['weight'] * value
    end

    { cost: total, breakdown: breakdown }
  end

  # >0: после этой заявки провайдер уйдёт выше целевой доли по количеству
  # (плохо); <0: всё ещё недобирает цель (бонус, cost со знаком минус).
  def self.traffic_share_deviation(provider, state)
    target = provider['traffic_percentage'].to_f / 100.0
    projected_total = state.total_approved_count + 1
    projected_share = (state.approved_count(provider['payment_system']) + 1).to_f / projected_total
    projected_share - target
  end

  # То же самое, но по денежному объёму (volume_share_pct), а не по count.
  def self.volume_share_deviation(provider, operation, state)
    target = (provider['volume_share_pct'] || provider['traffic_percentage']).to_f / 100.0
    amount = operation['amount'].to_f
    projected_total = state.total_approved_volume + amount
    return 0.0 if projected_total.zero?

    projected_volume = state.approved_volume(provider['payment_system']) + amount
    (projected_volume / projected_total) - target
  end

  # priority=1 -> 0.0 (предпочитаем), priority=99 (self-provider) -> ~1.0.
  def self.priority_component(provider)
    priority = provider['priority'].to_f
    [(priority - 1.0) / 98.0, 1.0].min
  end

  # Бонус, если ещё не набран daily_turnover_min; штраф, если приближается
  # к daily_turnover_max (или daily_amount_limit, если max не задан отдельно).
  def self.turnover_component(provider, state)
    used = state.daily_approved_amount(provider['payment_system'])
    value = 0.0

    if (min = provider['daily_turnover_min'])
      gap = 1.0 - (used / min.to_f)
      value -= [gap, 0.0].max
    end

    max = provider['daily_turnover_max'] || provider['daily_amount_limit']
    if max
      utilization = used / max.to_f
      value += utilization > 0.8 ? (utilization - 0.8) / 0.2 : 0.0
    end

    value
  end

  # Не хард-фильтр (тот уже применён), а мягкое предпочтение: заявка ближе
  # к центру диапазона провайдера -> он для неё "специализирован" -> ниже cost.
  # Даёт диапазону суммы влиять на ВЫБОР среди доступных, а не только
  # исключать недопустимых (см. жюри-критерий "Гибкость правил маршрутизации").
  def self.amount_fit_component(provider, operation)
    min = provider['limit_amount_min']
    max = provider['limit_amount_max']
    return 0.0 unless min && max && max > min

    position = (operation['amount'].to_f - min) / (max - min).to_f
    (position - 0.5).abs
  end
end

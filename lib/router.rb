# frozen_string_literal: true

require_relative 'hard_constraints'
require_relative 'soft_goals'
require_relative 'simulator'

# Обрабатывает одну заявку целиком:
#   1. hard-constraints -> eligible / skipped
#   2. spacepayments (self-provider) в сторону, используется только если
#      реальные кандидаты исчерпаны -- явное бизнес-правило, не полагаемся
#      на soft-goals веса
#   3. soft-goals считают cost для каждого кандидата
#   4. QuantumClient даёт полное ранжирование одним вызовом -- весь каскад
#      attempts строится из него без повторных запросов к Python
#   5. кандидаты пробуются по рангу, пока один не approved (или self-provider)
#   6. состояние провайдеров обновляется по факту
class Router
  REASON_QUANTUM = 'quantum_optimal'
  REASON_CLASSICAL = 'classical_fallback_optimal'
  REASON_ONLY_OPTION = 'only_eligible_provider'
  REASON_FALLBACK_SELF = 'fallback_self_provider'

  def initialize(providers:, state:, quantum_client:, strategies:, rng_seed:, quantum_opts: {})
    @providers = providers
    @state = state
    @quantum_client = quantum_client
    @strategies = strategies
    @rng_seed = rng_seed
    @quantum_opts = quantum_opts
  end

  def route(operation)
    eligible, skipped = HardConstraints.evaluate(operation, @providers, @state)

    real_eligible = eligible.reject { |r| r.provider == 'spacepayments' }
    self_provider_eligible = eligible.find { |r| r.provider == 'spacepayments' }

    attempts = skipped.map { |r| attempt_hash(r.provider, 'skipped', r.reason, r.details) }

    ranking, quantum_used = rank(real_eligible, operation)
    final_provider, final_result = attempt_cascade(ranking, operation, attempts, quantum_used)

    if final_provider.nil? && self_provider_eligible
      final_provider = attempt_self_provider(operation, attempts)
      final_result = 'approved'
    end

    build_decision(operation, final_provider, final_result, attempts)
  end

  private

  def attempt_cascade(ranking, operation, attempts, quantum_used)
    final_provider = nil
    final_result = nil

    ranking.each_with_index do |provider_name, idx|
      provider = provider_by_name(provider_name)
      @state.register_attempt(provider_name, operation['created_at'], operation['amount'])
      result = Simulator.simulate(provider, operation, seed: @rng_seed)
      @state.register_result(provider_name, operation['amount'], approved: result == 'approved')

      if result == 'approved'
        reason = if ranking.size == 1
                   REASON_ONLY_OPTION
                 else
                   quantum_used ? REASON_QUANTUM : REASON_CLASSICAL
                 end
        attempts << attempt_hash(provider_name, 'selected', reason, nil)
        final_provider = provider_name
        final_result = result
        break
      else
        attempts << attempt_hash(provider_name, 'skipped', "simulated_#{result}", "attempt ##{idx + 1}")
      end
    end

    [final_provider, final_result]
  end

  def attempt_self_provider(operation, attempts)
    provider = provider_by_name('spacepayments')
    @state.register_attempt('spacepayments', operation['created_at'], operation['amount'])
    Simulator.simulate(provider, operation, seed: @rng_seed, guaranteed: true)
    @state.register_result('spacepayments', operation['amount'], approved: true)
    attempts << attempt_hash('spacepayments', 'selected', REASON_FALLBACK_SELF,
                             'все внешние провайдеры отклонены/исчерпаны, self-provider обрабатывает гарантированно')
    'spacepayments'
  end

  def rank(eligible_results, operation)
    return [[], false] if eligible_results.empty?
    return [[eligible_results.first.provider], false] if eligible_results.size == 1

    candidates = eligible_results.map do |r|
      provider = provider_by_name(r.provider)
      { provider: r.provider, cost: SoftGoals.cost(provider, operation, @state, @strategies)[:cost] }
    end

    result = @quantum_client.rank(
      candidates,
      p: @quantum_opts[:p] || 2,
      shots: @quantum_opts[:shots] || 4096,
      restarts: @quantum_opts[:restarts] || 5,
      backend: @quantum_opts[:backend] || 'simulator'
    )
    ranking = result['ranking'] || candidates.sort_by { |c| c[:cost] }.map { |c| c[:provider] }
    quantum_used = result['fallback'] != true
    [ranking, quantum_used]
  end

  def provider_by_name(name)
    @providers.find { |p| p['payment_system'] == name }
  end

  def attempt_hash(provider, decision, reason, details)
    h = { 'provider' => provider, 'decision' => decision, 'reason' => reason }
    h['details'] = details if details
    h
  end

  def build_decision(operation, final_provider, final_result, attempts)
    provider = final_provider ? provider_by_name(final_provider) : nil
    {
      'operation_id' => operation['operation_id'],
      'selected_provider' => final_provider,
      'attempts' => attempts,
      'simulated_result' => final_result || 'rejected',
      'latency_sec' => provider ? provider['avg_latency_sec'].to_i : 0
    }
  end
end

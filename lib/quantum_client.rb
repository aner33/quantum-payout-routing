# frozen_string_literal: true

require "open3"
require "json"
require "timeout"

# Вызывает Qiskit/QAOA-решатель (quantum/quantum_router.py) для выбора
# провайдера из нескольких кандидатов, прошедших hard-constraints.
#
# Контракт: список {provider:, cost:} (cost уже посчитан в Ruby по активным
# soft-goals) -> полное ранжирование + победитель одним вызовом, без повторных
# subprocess-запросов на каждую попытку каскада.
#
# Любой сбой (нет python/qiskit, таймаут, битый вывод, ненулевой exit) --
# classical fallback по argmin, роутинг не останавливается. Различить можно
# через result["fallback"].
class QuantumClient
  class SolverError < StandardError; end

  DEFAULT_SCRIPT = File.expand_path("../quantum/quantum_router.py", __dir__)
  DEFAULT_TIMEOUT = 10 # seconds
  # python3 -- Linux/macOS; python -- обычный PATH после python.org на
  # Windows; py -3 -- Python Launcher for Windows.
  PYTHON_CANDIDATES = [["python3"], ["python"], ["py", "-3"]].freeze

  def initialize(python: nil, script: DEFAULT_SCRIPT, timeout: DEFAULT_TIMEOUT, logger: nil)
    @python = python || self.class.detect_python
    @script = script
    @timeout = timeout
    @logger = logger
  end

  # Первый рабочий интерпретатор из PYTHON_CANDIDATES; ничего не нашёл --
  # возвращает python3 по умолчанию, чтобы ошибка ниже была понятной.
  def self.detect_python
    PYTHON_CANDIDATES.find do |cmd|
      Open3.capture3(*cmd, "--version")
      true
    rescue Errno::ENOENT
      false
    end || PYTHON_CANDIDATES.first
  end


  # candidates: Array<Hash> with :provider / "provider" and :cost / "cost" keys
  # returns a Hash:
  #   "selected"      => String
  #   "ranking"       => Array<String>            best -> worst
  #   "probabilities" => Hash<String, Float>
  #   "energies"      => Hash<String, Float>       exact business cost per provider
  #   "meta"          => Hash                      solver diagnostics
  #   "fallback"      => true/false                whether the quantum step was bypassed
  def rank(candidates, penalty: nil, p: 2, shots: 4096, restarts: 5, backend: "simulator")
    raise ArgumentError, "candidates must not be empty" if candidates.empty?

    payload = { candidates: normalize(candidates), p: p, shots: shots, restarts: restarts, backend: backend }
    payload[:penalty] = penalty if penalty

    result = call_solver(payload)
    result["fallback"] = result.dig("meta", "fallback_classical") == true
    result
  rescue StandardError => e
    log("quantum solver failed (#{e.class}: #{e.message}) - falling back to classical argmin")
    classical_fallback(candidates).merge("fallback" => true, "error" => e.message)
  end

  private

  def normalize(candidates)
    candidates.map do |c|
      { provider: (c[:provider] || c["provider"]).to_s, cost: (c[:cost] || c["cost"]).to_f }
    end
  end

  def call_solver(payload)
    stdout_str = +""
    stderr_str = +""
    status = nil

    Open3.popen3(*@python, @script) do |stdin, stdout, stderr, wait_thr|
      stdin.write(JSON.generate(payload))
      stdin.close

      begin
        Timeout.timeout(@timeout) do
          stdout_str = stdout.read
          stderr_str = stderr.read
        end
      rescue Timeout::Error
        begin
          Process.kill("TERM", wait_thr.pid)
        rescue Errno::ESRCH
          nil
        end
        raise SolverError, "quantum solver timed out after #{@timeout}s"
      end

      status = wait_thr.value
    end

    raise SolverError, "exit #{status.exitstatus}: #{stderr_str}" unless status.success?

    parsed = JSON.parse(stdout_str)
    raise SolverError, parsed["error"] if parsed["error"]

    parsed
  rescue Errno::ENOENT
    raise SolverError, "python interpreter or quantum_router.py not found (#{@python.join(' ')} #{@script})"
  rescue JSON::ParserError => e
    raise SolverError, "malformed solver output: #{e.message}"
  end

  def classical_fallback(candidates)
    normalized = normalize(candidates)
    sorted = normalized.sort_by { |c| c[:cost] }
    providers = sorted.map { |c| c[:provider] }
    costs = sorted.map { |c| c[:cost] }

    {
      "selected" => providers.first,
      "ranking" => providers,
      "probabilities" => { providers.first => 1.0 },
      "energies" => providers.zip(costs).to_h,
      "meta" => { "fallback_classical" => true, "reason" => "quantum_client_exception" },
    }
  end

  def log(msg)
    @logger ? @logger.warn(msg) : warn(msg)
  end
end

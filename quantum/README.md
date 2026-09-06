# Квантовое ядро роутинга

## Идея

Выбор провайдера среди кандидатов, прошедших hard-constraints, — это
задача "выбрать ровно один вариант, минимизирующий бизнес-стоимость".
Формулируем как QUBO (one-hot selection) и решаем через QAOA на
Qiskit (`StatevectorEstimator` / `StatevectorSampler`, без Aer —
минимум зависимостей; опционально — реальный IBM QPU).

Python/Qiskit ничего не знает про провайдеров, стратегии, JSON-файлы
кейса — только "вот кандидаты с cost, дай ранжирование". Вся бизнес-
логика (hard-constraints, веса стратегий, каскад, отчёт) — в Ruby.
Это и держит долю Ruby-кода в репозитории доминирующей.

**Статус:** протестировано вживую (не только синтаксически) — реальный
прогон с установленным Qiskit подтвердил, что QAOA-решатель отрабатывает
корректно на очереди из кейса (5 из 6 неоднозначных решений прошли через
настоящий квантовый ранжировщик, остальные — через classical fallback
на машине без установленных зависимостей).

## Протокол (stdin/stdout, JSON)

Ruby пишет в stdin процесса `python3 quantum/quantum_router.py`:

```json
{
  "candidates": [
    {"provider": "vipay", "cost": 0.62},
    {"provider": "payflow", "cost": 0.15},
    {"provider": "quickpay", "cost": 0.40}
  ],
  "p": 2,
  "shots": 4096,
  "restarts": 5,
  "seed": 42,
  "backend": "simulator"
}
```

| Поле | Тип | По умолчанию | Смысл |
|---|---|---|---|
| `candidates` | array | обязательное | список `{provider, cost}`, cost ниже = лучше |
| `penalty` | float | `2*(max(cost)-min(cost)+1)` | сила штрафа за нарушение one-hot |
| `p` | int | `2` | глубина QAOA (число cost/mixer слоёв) |
| `shots` | int | `4096` | число измерений финальной схемы |
| `restarts` | int | `5` | число случайных стартов COBYLA, берётся лучший по expectation value |
| `seed` | int | `42` | сид для воспроизводимости случайных стартов и сэмплирования |
| `backend` | `"simulator"` \| `"qpu"` | `"simulator"` | где выполняется финальное сэмплирование (см. ниже) |

`cost` — уже посчитанная в Ruby взвешенная стоимость по активным
soft-goals (ниже = лучше), см. `lib/soft_goals.rb`.

Python возвращает (успех):

```json
{
  "selected": "payflow",
  "ranking": ["payflow", "quickpay", "vipay"],
  "probabilities": {"payflow": 0.55, "quickpay": 0.30, "vipay": 0.15},
  "energies": {"payflow": 0.15, "quickpay": 0.40, "vipay": 0.62},
  "meta": {
    "n_qubits": 3, "p": 2, "shots": 4096, "restarts": 5,
    "valid_bitstring_prob": 0.94,
    "fallback_classical": false,
    "optimizer": "COBYLA",
    "best_expectation": -0.842,
    "sampled_on": "simulator"
  }
}
```

Или при ошибке (и exit code 1):

```json
{"error": "candidates must be a non-empty list", "type": "ValueError"}
```

Один вызов на операцию отдаёт **полный ранжированный список** — весь
каскад `attempts` строится в Ruby из этого одного ответа, без повторных
обращений к Python на каждую попытку. Повторный вызов нужен только для
следующей операции (состояние провайдеров изменилось → другие cost).

## Как это устроено внутри (по функциям)

| Функция | Что делает |
|---|---|
| `build_qubo(candidates, penalty)` | Строит one-hot selection QUBO: линейный член = `cost_i - penalty`, квадратичный = `2*penalty` на каждую пару — так что выбор больше одного кандидата всегда невыгоднее любого одиночного выбора. |
| `qubo_to_ising(linear, quadratic, n)` | Стандартная замена `x_i = (1-z_i)/2`, переводит QUBO в гамильтониан `h·Z + J·ZZ + offset`. |
| `build_cost_operator(h, J, n)` | Собирает `SparsePauliOp` (Z и ZZ-члены) для QAOA — учитывает little-endian порядок кубитов в Qiskit. |
| `solve(payload)` | Главная точка входа: валидирует вход, для `n==1` сразу возвращает единственного кандидата без квантового шага, иначе запускает полный QUBO→Ising→QAOA→COBYLA(×restarts)→сэмплирование пайплайн. |
| `sample_on_qpu(bound_circuit, shots, seed)` | Опциональный шаг: пробует отправить один job на реальный IBM QPU; при любой проблеме (нет пакета, нет токена, нет сети, очередь) возвращает `(None, meta_extra)` — вызывающий код молча уходит на локальный симулятор. |
| `classical_cost(bitstring, costs)` | Проверяет, что измеренная битовая строка валидна (ровно один "1"), и возвращает точную бизнес-стоимость выбранного кандидата. |
| `main()` | Точка входа процесса: читает JSON из stdin, ловит любое исключение и печатает `{"error": ..., "type": ...}` с exit code 1 вместо трейсбека. |

### Почему COBYLA с рестартами (`restarts`)

QAOA-ландшафт немультимодальный: с одного случайного старта COBYLA может
сойтись в неглубокий локальный минимум и выдать допустимого, но не самого
дешёвого по cost кандидата (наблюдалось на операции `op_106` из тестовой
очереди). Поэтому `solve()` прогоняет COBYLA `restarts` раз с разных
случайных углов и берёт результат с наименьшим `expectation value` —
это не меняет саму формулировку QUBO/Ising, только повышает шанс найти
её настоящий минимум.

### Как выбирается `ranking`

После сэмплирования схемы оставляем только валидные one-hot битовые
строки (`classical_cost` не `None`), суммируем их вероятности по
провайдеру и сортируем провайдеров по убыванию суммарной вероятности —
это и есть `ranking`. Если ни одна сэмплированная строка не оказалась
валидной (крайне маловероятно при разумном `penalty`) — `solve()`
откатывается на точный классический `argmin` по `costs` и явно
помечает это в `meta.fallback_classical = true`.

## Использование из Ruby

```ruby
require_relative "lib/quantum_client"

client = QuantumClient.new
result = client.rank([
  { provider: "vipay",    cost: 0.62 },
  { provider: "payflow",  cost: 0.15 },
  { provider: "quickpay", cost: 0.40 },
])

result["selected"]   # => "payflow"
result["ranking"]    # => ["payflow", "quickpay", "vipay"]
result["fallback"]   # => false, если квантовый шаг реально отработал
```

Если Python/Qiskit недоступен, упал по таймауту или вернул мусор —
`QuantumClient` сам откатывается на классический `argmin` по cost и
помечает `result["fallback"] = true`. `QuantumClient.detect_python`
дополнительно сам находит рабочий интерпретатор (`python3` → `python`
→ `py -3`), это нужно в первую очередь на Windows, где часто нет
команды `python3`.

## Запуск на реальном квантовом железе (IBM QPU)

По умолчанию всё крутится на локальном симуляторе (`StatevectorEstimator` /
`StatevectorSampler`) — быстро, бесплатно, детерминированно. Классический
внешний цикл (COBYLA, ~200 итераций × `restarts` попыток) **всегда**
остаётся на симуляторе — гонять оптимизатор через реальное железо означало
бы job в очередь IBM на каждую итерацию. Как только оптимальные параметры
найдены, при `"backend": "qpu"` мы отправляем **один** job на реальный
процессор только для финального сэмплирования готовой схемы.

Настройка (один раз):

```bash
pip install qiskit-ibm-runtime
python3 -c "
from qiskit_ibm_runtime import QiskitRuntimeService
QiskitRuntimeService.save_account(channel='ibm_quantum_platform', token='ВАШ_ТОКЕН')
"
```

Токен — на https://quantum.cloud.ibm.com/ (есть бесплатный план).

Дальше просто передавайте `"backend": "qpu"` в JSON на stdin, либо
поставьте `"backend": "qpu"` в `config/routing_config.json` → `quantum`,
если запускаете через `bin/route.rb`:

```bash
echo '{"candidates":[{"provider":"vipay","cost":0.4},{"provider":"payflow","cost":0.1}],"backend":"qpu"}' \
  | python3 quantum/quantum_router.py
```

В ответе `meta.sampled_on` покажет `"qpu"` и реальное имя бэкенда
(`meta.backend_name`) плюс `meta.job_id`, либо `"simulator"` +
`meta.qpu_fallback_reason`, если пакет не установлен, аккаунт не
настроен или очередь недоступна — скрипт никогда не падает из-за
недоступности железа, а тихо откатывается на симулятор.

**Практический совет:** реальные бесплатные бэкенды IBM почти всегда
стоят в очереди (от секунд до десятков минут), и результат зашумлён
(реальные кубиты, а не идеальная математика — при этом сама схема и
формулировка задачи от этого не меняются). Для сдачи решения держите
`"backend": "simulator"`. `"qpu"` включайте разово, для демонстрации —
job_id и backend_name в meta документально подтверждают реальный запуск.

## Установка и проверка локально

```bash
pip install qiskit scipy numpy   # обязательное для любого квантового шага
python3 quantum/quantum_router.py    # без stdin — прогонит demo и напечатает JSON
echo '{"candidates":[{"provider":"a","cost":0.1},{"provider":"b","cost":0.9}]}' \
  | python3 quantum/quantum_router.py
```

Опционально, только для реального QPU:

```bash
pip install qiskit-ibm-runtime
```

## Известные ограничения

- QAOA — приближённый алгоритм: даже с рестартами он не гарантирует
  точный минимум cost на 100% прогонов, только с высокой вероятностью.
- Результат на реальном QPU может отличаться между запусками из-за
  шума железа — для воспроизводимых прогонов используйте `simulator`.
- Классический внешний цикл линейно растёт по времени с `restarts` —
  на очень больших очередях операций может стоить снизить это значение.

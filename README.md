# Умный роутинг выплат

Квантово-оптимизированный движок маршрутизации платежей между
провайдерами: жёсткая фильтрация по бизнес-правилам → взвешенное
ранжирование кандидатов через QAOA (Qiskit) с классическим fallback →
каскад попыток → гарантированный self-provider fallback.

Полная техническая документация: [`docs/quantum-routing-doc.docx`](docs/quantum-routing-doc.docx).
Отдельно про квантовое ядро: [`quantum/README.md`](quantum/README.md).

## Быстрый старт

```bash
# Ruby 3.3.0 (см. .ruby-version)
ruby bin/route.rb data/operations_queue.json routing_decisions routing_report

# Проверка официальным скриптом организаторов
ruby scripts/validate_*.rb routing_decisions.json

# Аналитика/калибровка по исторической выгрузке
ruby bin/analyze_history.rb
```

Квантовый шаг опционален: без `qiskit`/`scipy`/`numpy` система
автоматически считает то же самое классическим `argmin` и работает
без единой ошибки (см. `quantum/README.md` про честную маркировку
`quantum_optimal` vs `classical_fallback_optimal`).

```bash
pip install qiskit scipy numpy       # для настоящего квантового шага
pip install qiskit-ibm-runtime       # опционально, для запуска на реальном IBM QPU
```

## Структура репозитория

```
bin/route.rb              — точка входа: прогон очереди операций
bin/analyze_history.rb    — аналитика по data/operations_history.csv
lib/                       — вся бизнес-логика (Ruby)
quantum/quantum_router.py  — квантовое ядро (QUBO → Ising → QAOA)
config/routing_config.json — веса стратегий, оверрайды провайдеров, квантовые параметры
data/                       — входные данные кейса
scripts/validate_*.rb      — официальный скрипт проверки от организаторов
docs/                       — техническая документация и презентация
```

## Что внутри

- **11 hard-constraints**, порядок и логика идентичны официальному
  validate-скрипту.
- **6 комбинируемых soft-goals стратегий** (доли по количеству/объёму,
  каскадный приоритет, конверсия, оборотные обязательства, попадание в
  диапазон суммы).
- **QAOA-ранжирование** с классическим fallback и честной пометкой,
  какой путь реально сработал.
- **Аналитика по истории**: выявлено расхождение заявленной и реальной
  конверсии одного из провайдеров на 43,6 п.п. — см. `bin/analyze_history.rb`.

## Известные ограничения

См. раздел 9 в `docs/quantum-routing-doc.docx`.

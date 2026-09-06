# Changelog

## v1.1 — доработки после первого прогона на Windows

- Fix: `.ruby-version` был сохранён в UTF-16 с BOM вместо обычного
  текста — не распознавался версионными менеджерами Ruby.
- Fix: `quantum_client.rb` был жёстко завязан на команду `python3`,
  которой часто нет в PATH на Windows. Теперь `QuantumClient.detect_python`
  сам пробует `python3` → `python` → `py -3`.
- Fix: поле `reason` у выбранного провайдера всегда указывало
  `"quantum_optimal"`, даже когда реально сработал classical fallback.
  Теперь `reason` берётся из фактического результата решателя
  (`quantum_optimal` / `classical_fallback_optimal`).
- Feature: multi-restart для COBYLA (`config.quantum.restarts`, по
  умолчанию 5) — снижает шанс, что QAOA застрянет в неглубоком локальном
  минимуме на одном случайном старте.
- Feature: `bin/analyze_history.rb` — калибровка и сверка текущих
  метрик провайдеров (`conversion_24h`, `traffic_percentage`) с
  фактическими данными из `data/operations_history.csv`. Обнаружено
  расхождение заявленной и фактической конверсии payflow на 43,6 п.п.
- Docs: полная техническая документация (`docs/quantum-routing-doc.docx`),
  презентация для защиты (`docs/quantum-routing-deck.pptx`), развёрнутый
  `quantum/README.md`, корневой `README.md`.

## v1.0 — первая рабочая версия

- Hard-constraints (11 проверок), soft-goals (6 стратегий), QAOA-ранжирование
  с классическим fallback, каскад попыток, self-provider fallback.
- Независимая кросс-проверка логики дала идентичный результат с Ruby-кодом.
- Официальный `scripts/validate_*.rb`: 29/29 проверок, 0 ошибок.

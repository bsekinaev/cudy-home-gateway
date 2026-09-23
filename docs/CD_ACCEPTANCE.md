# CI/CD: проверка перед активацией

База патча: `05a0025bbb4d1cbfcd7d4303228e330b9d23e8a1` (`feature/health-alerts`).

## Проверено локально

Python 3.12.14, Linux, /bin/sh = dash.

- 13 тестов сборщика/проверки release bundle.
- 29 тестов deployment/provenance/transport:
  - build → manifest verification → wire protocol → настоящий receiver plan;
  - read-only plan, update, NO_CHANGE и ручной rollback;
  - сохранение running/stopped состояния службы;
  - проверка и восстановление содержимого и прав;
  - ошибки текущего preflight и нового post-check;
  - отказ записи target-файла с восстановлением;
  - SIGKILL после первой замены и последующий recover;
  - имитация reboot: потеря runtime lock при сохранённом journal;
  - SIGHUP после приёма запроса;
  - блокировка параллельной установки, проверка места;
  - повреждённый backup, drift до rollback;
  - ссылки, усечённый запрос, лишние данные, неправильные хеши и права;
  - provenance CI: fork/PR/другая ветка/другой SHA/failed run запрещены;
  - отказ неизвестных команд forced-command wrapper.
- POSIX shell syntax, YAML parsing, git diff --check.
- Применение итогового патча к чистой копии исходной базы.

Gateway, procd и ucode в интеграционных тестах заменены тестовыми программами.
Синхронизация диска и задержки в тестах сокращены. Физическая потеря питания,
износ flash и поведение ядра OpenWrt на этом стенде не моделируются.

## Требует реального запуска после применения патча

- Новый GitHub CI, включая BusyBox ash + applets, настоящий ucode build,
  compilation runtime и Incident Engine selftest.
- Bootstrap receiver на CUDY; отдельные ключ и tag:cd; environment production.
- Deploy CUDY: plan → apply → status → повторный apply (NO_CHANGE).
- Ручной rollback → Router Smoke → повторный apply.
- Штатная перезагрузка CUDY и повторный Router Smoke.

Причины невыполнения из среды разработки: LAN SSH вернул Network is unreachable;
GitHub write API вернул 403 Resource not accessible by integration. Новый CI
не запускался из этой среды. Старый зелёный CI не является проверкой этого патча.

Рабочий production CD считается принятым только после успешного выполнения
этого списка на реальном роутере. Руководство: [DEPLOYMENT.md](DEPLOYMENT.md).

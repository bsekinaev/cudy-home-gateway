# Возобновление безопасного owner update

> Execution: inline; проверить весь итоговый набор изменений отдельным reviewer.

Цель: довести PR #31 до проверяемого кандидата после подтверждения владельцем,
что REDMI восстановлен. Контракт: docs/HGDEPLOY2_OWNER_UPDATE.md.
Сетевую конфигурацию и установленный runtime не менять.

- [x] Проверить main, PR #31, review threads и CI исходного HEAD.
- [x] Объединить документацию main с production evidence PR #31 в README.
- [x] Воспроизвести ошибки выбранного ref и превышения лимита acceptance.
- [x] Ограничить сборку checkout выбранной версии и проверить её зависимости.
- [x] Ограничить acceptance 262144 байтами до JSON parsing.
- [x] Воспроизвести и исправить Windows separators в tar directory entries.
- [x] Локальные builder regressions: 9 tests PASS.
- [ ] Отдельный review, исправление существенных замечаний.
- [ ] CI нового коммита, native OpenWrt owner-update report, crash/reboot recovery.
- [ ] После всех gates: OWNER_MANUAL kit, SHA256, runner и owner preflight.

Решения: --ref другого commit требует checkout этого commit, вместо исполнения
Python-модулей произвольного ref. Исторический production evidence сохраняется.
Повторная миграция, прямое копирование poller и подмена pins запрещены.

Дополнение после adversarial review: CI исходного f8a011c завершился 13/13 PASS,
но найден пробел: guardian завершал quiesce без отзыва legacy numeric-PID
admission. Нулевой review receipt этого SHA отозван; owner release запрещён.
Исправление должно удалить только собственный pid marker, сохранив recovery
identity, и согласовать quiesce с migration startup lock. Добавлены проверки
повторного запуска с reused PID и задержанной регистрации ручного start.
Все gates требуют нового exact-source CI и VM evidence.

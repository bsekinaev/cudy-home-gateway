# HGDEPLOY2 RC A — проверка пакета без production migration

Поставка **A_ISOLATED_ONLY**. Production apply заблокирован в PowerShell,
целевом entrypoint и native coordinator. Это не готовность поставки B.

Состав: SHA256/metadata manifest, candidate из20 runtime+3 receiver,
доверенные legacy receiver/wrapper/init, синтетический HGDEPLOY1 fixture,
native journal/snapshot/candidate/coordinator/rollback, read-only preflight,
PowerShell owner runner. Python на роутере не нужен.

Скачайте owner.ps1 и архив по опубликованным URL с40-символьным Git commit.
Сверьте SHA256 owner.ps1 перед запуском; runner проверяет SHA256 архива локально
и после SCP. Не используйте branch URL, latest или непроверенные файлы.
Windows11: нужны штатные PowerShell5.1+, OpenSSH ssh/scp и tar.exe.
SSH использует StrictHostKeyChecking=yes; неизвестный ключ не принимается
автоматически. Пароль не сохраняется; стандартный SSH может запросить его.

Runner принимает Target=root@192.168.1.1, BundleUrl, BundleSha256, SessionFile
и Stage. Значение Stage по умолчанию — Preflight. Все параметры SHA/URL должны
быть взяты из отчёта именно этого RC. Последовательность:

1. `-Stage Preflight`: upload/extract только в новом приватном /tmp kit;
   проверка пакета и **read-only** текущего production HGDEPLOY1/трёх pins.
2. `-Stage Prepare`: новый `/tmp/hgdeploy2-rc-a.XXXXXX`; синтетическая установка
  18 файлов через trusted legacy engine, snapshots и PREPARED. Production
  runtime, journal, /etc/home-gateway и службы не изменяются.
3. `-Stage Apply`: только identified synthetic lab,20+3 файлов и HGDEPLOY2 anchor.
4. `-Stage Verify`: hashes/metadata/inventory/latest внутри этого lab.
5. `-Stage Rollback`: explicit verified возврат lab к18+3 и старому journal/latest.
   Можно повторить rollback. Snapshots и fence остаются для диагностики.

`-Stage All` явно выполняет первые4 этапа; rollback запускается отдельно.
Ни скачивание, ни Preflight не запускают apply. При ошибке runner прекращает
работу, сохраняет session и не делает auto apply/rollback. Не повторяйте Apply
после обрыва SSH: используйте explicit Rollback для lab из session.
Если RC_LAB не получен или состояние/ownership/marker неизвестны — STOP,
сохраните вывод; не угадывайте путь и не удаляйте чужие locks.

Удалять lab/kit автоматически runner не будет. Старые owner test directories,
включая `/tmp/hg-native-main.cPHJib`, не трогаются. /tmp очищается при reboot,
поэтому не перезагружайте CUDY ради этой проверки. Потеря /tmp означает потерю
только synthetic lab; реальная установка этим пакетом не заменялась.

Не выполняются reboot, restart production Telegram/VPN/PassWall2/Xray,
изменения UCI/nft/routes/DNS. Gateway58 selftests и11 doctor checks повторно
не запускаются. Synthetic service fixture не доказывает Telegram/procd lifecycle:
отчёт явно содержит SERVICE_LIFECYCLE=NOT_TESTED и PRODUCTION_APPLY=BLOCKED.

Для поставки B остаются обязательными control-file snapshot/publication/rollback,
Telegram lifecycle, terminal admission и полная production installer acceptance.
Кабельный recovery path должен быть доступен перед будущей опасной операцией;
эта поставка не выдаёт Ethernet/restore за PASS.

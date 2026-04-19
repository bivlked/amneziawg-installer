<p align="center">
  <b>RU</b> Русский | <b>EN</b> <a href="CHANGELOG.en.md">English</a>
</p>

# Changelog

Все заметные изменения в проекте документируются в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/).

---

## [Unreleased]

---

## [5.10.1] — 2026-04-19

Совместимость с зеркалами без source-пакетов (Hetzner, AWS и др.) — [Discussion #47](https://github.com/bivlked/amneziawg-installer/discussions/47).

### Исправлено

- **`apt update` не падает на 404 для source-пакетов.** Некоторые зеркала (Hetzner Ubuntu, AWS Ubuntu) не раздают source-пакеты, но дефолтный `/etc/apt/sources.list.d/ubuntu.sources` содержит `Types: deb deb-src`. Наш прежний `apt update -y || die` падал с ошибкой. Новая функция `apt_update_tolerant` (в `awg_common.sh`) игнорирует 404 только на `source`/`Sources`/`deb-src`, но пропускает все остальные ошибки (GPG, network, недоступный PPA).
- **Удалена модификация `/etc/apt/sources.list.d/ubuntu.sources`.** Скрипт больше не включает `deb-src` — мы никогда не использовали source-пакеты (kernel module ставится через DKMS + бинарные headers), так что модификация была лишней и создавала проблему.

### Тесты

- **+6 новых bats-тестов** (137 total, было 131). `test_apt_tolerant.bats`: clean update, source-only 404, deb-src 404, GPG error, binary 404, смешанные ошибки.

---

## [5.10.0] — 2026-04-16

Оптимизация для мобильных сетей: CLI-флаги `--preset=mobile` и `--jc`/`--jmin`/`--jmax`, комплексный аудит безопасности и надёжности всего кодовой базы ([Discussion #38](https://github.com/bivlked/amneziawg-installer/discussions/38), [Issue #42](https://github.com/bivlked/amneziawg-installer/issues/42)).

### Добавлено

- **CLI-флаг `--preset=mobile` для мобильных сетей.** Фиксирует Jc=3, узкий Jmax (Jmin+20..80) — подтверждённые настройки для Tele2, Yota, Мегафон, Таттелеком и других операторов, блокирующих AWG с Jc>3 и Jmax>300. Также доступен `--preset=default` для явного выбора стандартного профиля (Jc=3-6, Jmin=40-89, Jmax=Jmin+50..250).
- **CLI-флаги `--jc=N`, `--jmin=N`, `--jmax=N`.** Точечное переопределение параметров обфускации поверх любого preset. Jc: 1-128, Jmin/Jmax: 0-1280, Jmax должен быть ≥ Jmin. Пример: `--preset=mobile --jc=4` использует mobile-профиль, но с Jc=4 вместо 3.
- **Валидация протокольных границ в `validate_awg_config`.** Проверка AWG-параметров после восстановления из бэкапа: Jc (1-128), Jmin/Jmax (0-1280, Jmax ≥ Jmin), S3 (0-64), S4 (0-32), корректность H1-H4 диапазонов (нижняя граница < верхней).
- **Сохранение `AWG_PRESET` в конфигурацию.** Выбранный preset записывается в `awgsetup_cfg.init` для диагностики и воспроизводимости.

### Безопасность

- **Защита конфигурационного парсера от BOM и CRLF.** `safe_load_config` и `safe_read_config_key` теперь удаляют BOM (UTF-8 `\xEF\xBB\xBF`) и CR (`\r`) перед парсингом. Защищает от проблем при редактировании конфигов в Windows-редакторах.
- **Экранирование спецсимволов в `regenerate_client`.** `sed`-замены корректно экранируют `&`, `\`, `/` в значениях, предотвращая инъекцию через ключи клиента.
- **Привязка GitHub Actions к SHA-хешам.** Все 7 actions в 4 workflow привязаны к конкретным SHA вместо мутабельных тегов (supply chain protection).
- **Маскирование endpoint в диагностическом отчёте.** Функция `generate_diagnostic_report` заменяет IP-адрес сервера на `***MASKED***` для безопасной публикации отчётов.
- **Права доступа для vpn:// URI.** `secure_files` и `restore_backup` устанавливают `chmod 600` для файлов `.vpnuri` и `.png` (QR-коды).
- **Валидация имени клиента в `set_client_expiry`.** Защита от path traversal через имя клиента.
- **Кавычки в путях cron-файла.** `install_expiry_cron` корректно обрамляет пути с пробелами.

### Надёжность

- **Устранение TOCTOU в `modify_client`.** Валидация параметров вынесена до захвата лока, проверка состояния клиента — внутри лока. File descriptor корректно закрывается на всех путях ошибки.
- **Корректный restart сервиса.** Шаг 7 теперь определяет уже запущенный сервис и использует `enable + restart` вместо повторного `awg-quick up`, предотвращая ошибку «interface already exists».
- **Устранение утечки I1.** `load_awg_params` очищает `AWG_I1` перед парсингом серверного конфига, предотвращая подмену CPS-параметра значением из начальной конфигурации.
- **Корректная перегенерация при CLI-флагах.** При повторном запуске с `--preset` или `--jc`/`--jmin`/`--jmax` параметры AWG принудительно перегенерируются, даже если конфиг уже существует.
- **Завершение шага при ARM prebuilt.** Путь установки через prebuilt `.deb` теперь корректно обновляет state и запрашивает перезагрузку, предотвращая бесконечный цикл шага 2.
- **Корректный формат regex в `release.yml`.** Экранированы точки в паттерне версии (`5\.10\.0` вместо `5.10.0`).
- **Preflight-проверки в `build-arm-deb.sh`.** Добавлены проверки `modinfo`, `sha256sum`, `awk`, `xz`, определение kernel через `/lib/modules/*/build`, guard на пустой `MODULE_VER`.

### CI/CD

- **Расширение scope ShellCheck.** Workflow теперь линтит `scripts/*.sh` и `tests/*.bash` помимо корневых `.sh`.
- **Hygiene для test.yml.** Добавлены `permissions: contents: read` и `concurrency` group для предотвращения параллельных прогонов.

### Тесты

- **+33 новых bats-теста** (131 total, было 98). `test_preset.bats` (18): preset selection, CLI overrides, валидация. `test_validate.bats` (+8): протокольные границы. `test_safe_load_config.bats` (+4): CRLF, BOM, BOM+CRLF, значения с `=`. `test_validate_endpoint.bats` (+3): полный IPv6, single-label hostname, пустые скобки.

> 📣 **Основные возможности ветки 5.x** — в [v5.8.0 release notes](https://github.com/bivlked/amneziawg-installer/releases/tag/v5.8.0). ARM-поддержка — в [v5.9.0](https://github.com/bivlked/amneziawg-installer/releases/tag/v5.9.0). v5.10.0 — оптимизация для мобильных сетей и комплексный аудит без breaking changes.

---

## [5.9.0] — 2026-04-15

Поддержка Raspberry Pi (arm64 и armhf) и серверов на ARM64 (AWS Graviton, Oracle Ampere, Hetzner arm64). Полная реализация от [@pyr0ball](https://github.com/pyr0ball) ([PR #43](https://github.com/bivlked/amneziawg-installer/pull/43), [Issue #37](https://github.com/bivlked/amneziawg-installer/issues/37)).

### Добавлено

- **Prebuilt kernel modules для ARM.** Новый GitHub Actions workflow (`.github/workflows/arm-build.yml`) собирает `amneziawg.ko` для 6 ARM-таргетов через QEMU при каждом push тега `v*`. Таргеты: `rpi-bookworm-arm64` (Raspberry Pi 3/4), `rpi5-bookworm-arm64` (Pi 5 / Cortex-A76), `rpi-bookworm-armhf` (Pi 3/4 32-bit), `ubuntu-2404-arm64`, `ubuntu-2204-arm64`, `debian-bookworm-arm64`. Готовые `.deb` + `.sha256` публикуются в отдельный release `arm-packages`. Build-скрипт — `scripts/build-arm-deb.sh`, можно запускать вручную на ARM-железе вне CI.
- **Автоматический выбор пути установки на ARM.** На `aarch64`/`armv7l` шаг 2 сначала пробует prebuilt `.deb` из `arm-packages` (kernel vermagic должен совпадать точно), при несовпадении молча откатывается на DKMS. Curl с `--max-time 60` от зависаний, SHA256 проверяется перед `dpkg -i`. Экономит время и RAM на минимальных системах без build-tools.
- **Корректное определение kernel headers для Raspberry Pi.** Ядра RPi Foundation (`+rpt`/`-rpi` суффикс) теперь подтягивают `linux-headers-rpi-v8` или `linux-headers-rpi-2712` вместо несуществующего `linux-headers-arm64`. `amneziawg-tools` (userspace) на ARM уже поставляется через PPA для arm64/armhf — отдельная сборка не нужна.
- **Bats-тесты для header selection.** `tests/test_rpi_headers.bats` — 6 сценариев: `+rpt-rpi-v8` → `rpi-v8`, `+rpt-rpi-2712` → `rpi-2712`, legacy `-rpi-v8`, mainline arm64 Debian, amd64, generic Ubuntu kernel.

### Тесты

- **x86_64 regression** на чистом Ubuntu 24.04 LTS, kernel 6.8.0-110-generic: DKMS сборка, загрузка модуля, `awg show`, `manage add/list/backup`, uninstall — всё без изменений. ARM-путь корректно пропускается на x86_64, `_try_install_prebuilt_arm` не вызывается.
- **ARM end-to-end** на Raspberry Pi 4 / Debian 12 / kernel `6.12.75+rpt-rpi-v8` (DKMS-путь, prebuilts ещё не опубликованы на момент PR): full install lifecycle, `awg-quick@awg0` active, vermagic совпадает.

### Вне этого релиза

- OpenWrt — отдельная pkg-экосистема, нужен OpenWrt SDK
- Авто-трекинг обновлений ядра / detection сломанных пакетов
- Armbian и прочие SBC vendor-ядра (отдельные follow-up)

> 📣 **Основной relnotes пакет для ветки 5.x** — в [v5.8.0 release notes](https://github.com/bivlked/amneziawg-installer/releases/tag/v5.8.0). v5.9.0 — minor bump, добавление ARM-поддержки без breaking changes для существующих x86_64 установок.

---

## [5.8.4] — 2026-04-13

Hardening-фиксы надёжности и безопасности по результатам ревью установщика и скрипта управления.

### Безопасность

- **Расширенная проверка типов файлов в `restore_backup`.** Verbose-листинг архива (`tar -tvzf`) теперь проверяет тип каждого entry по первому символу. Архивы с блочными устройствами (`b`), символьными устройствами (`c`), FIFO (`p`), hardlink (`h`) или symlink (`l`) внутри отклоняются ещё до распаковки. Параллельно добавлен флаг `--no-same-permissions` при извлечении: права файлов всегда выставляются из umask процесса, не из метаданных архива. Защита от crafted-архивов, которые обходили проверку путей v5.8.3.
- **Валидация диапазона октетов IPv4 в `validate_endpoint`.** Ранее регулярное выражение допускало `999.0.0.1` как "валидный" IPv4 (паттерн `[0-9]{1,3}` не проверял числовое значение). Теперь добавлен второй проход через `BASH_REMATCH`: каждый октет проверяется как число в диапазоне 0-255. `validate_endpoint "256.0.0.1"` и `validate_endpoint "999.999.999.999"` теперь корректно возвращают 1.
- **`restore_backup` — прерывание при первой ошибке копирования.** Все 5 критических операций `cp -a` (server/, clients/, keys/, server_private.key, server_public.key) теперь явно проверяются на ошибку. При сбое — снимаются оба лока и функция немедленно возвращает 1 с описанием какой именно файл не удалось скопировать. Предотвращает сценарий полу-восстановленной конфигурации.

### Надёжность

- **Файловые локи в `backup_configs` и `restore_backup`.** `backup_configs()` теперь захватывает `.awg_backup.lock` (таймаут 30 сек) перед созданием архива. `restore_backup()` захватывает `.awg_backup.lock` (внешний) плюс `.awg_config.lock` (внутренний, 30 сек) перед извлечением. Порядок захвата фиксирован (backup → config), deadlock исключён. При конкурентном запуске `manage backup` и `manage restore` второй процесс ждёт или завершается с диагностикой.
- **Предотвращение self-deadlock в `restore_backup`.** До этого фикса `restore_backup()` вызывала `backup_configs()` для safety snapshot — оба пытались захватить `.awg_backup.lock` → deadlock. Выделена внутренняя функция `_backup_configs_nolock()`, которую `restore_backup()` вызывает уже внутри своего locked scope. `backup_configs()` (публичный entry point) остаётся с собственным локом.
- **UFW exit code checks в `setup_improved_firewall`.** Каждая команда `ufw` (default deny/allow, limit SSH, allow VPN port, route rule) на обоих ветках (inactive и active) теперь проверяет exit code. Аккумулированные ошибки → `return 1`. Ранее ошибка одного правила UFW не прерывала настройку firewall.
- **SHA256 bypass логируется на уровне WARN.** При старте с переопределённым `AWG_BRANCH` (тест кастомной ветки) пропуск проверки SHA256 ранее молча шёл через `log_debug`. Теперь — `log_warn`, чтобы разработчик и в verbose-логе видел что целостность не проверялась.

### Тесты

- **+7 новых bats-тестов.** `test_validate_endpoint.bats` +4: отклонение `999.999.999.999`, `256.1.1.1`; принятие `255.255.255.255`, `0.0.0.0`. `test_restore_backup.bats` +1: реальный архив + mock-tar с block device entry → тип-чек отклоняет (негативный тест, проверяет корректное отклонение опасных entry). `test_apply_config.bats` +2: flock timeout возвращает 1; systemctl restart failure → non-zero. Всего **92 bats-теста**, все PASS.

> 📣 **Основной relnotes пакет для ветки 5.8.x** — в [v5.8.0 release notes](https://github.com/bivlked/amneziawg-installer/releases/tag/v5.8.0). v5.8.4 — hardening-фиксы поверх 5.8.3 без breaking changes.

---

## [5.8.3] — 2026-04-11

Набор hardening-фиксов и точечных улучшений по мотивам [Issue #42](https://github.com/bivlked/amneziawg-installer/issues/42) и внутреннего аудита.

### Безопасность

- **Проверка целостности скачиваемых скриптов (SHA256).** `install_amneziawg.sh` в шаге 5 теперь считает `sha256sum` для `awg_common.sh` и `manage_amneziawg.sh` сразу после `curl` и сверяет с hardcoded значениями, которые обновляются при каждом релизе. При несовпадении — установка прерывается. Защита от подмены на транзитном узле или при компрометации raw.githubusercontent.com. Проверка автоматически пропускается если `AWG_BRANCH` переопределён пользователем для теста кастомной ветки.
- **Валидация tar-архива перед распаковкой в `restore_backup`.** До распаковки скрипт читает список файлов через `tar -tzf` и отклоняет архив если внутри есть абсолютные пути (`/etc/...`) или path traversal (`..`). После распаковки — ищет symlinks в распакованном дереве и отклоняет архив при их наличии. Плюс `tar -xzf --no-same-owner` для гарантии того что владелец файлов — root, а не метаданные архива. Защита от crafted или подменённого бэкапа.

### Исправлено

- **Мобильный интернет — Yota/Tele2 блокировали VPN ([Issue #42](https://github.com/bivlked/amneziawg-installer/issues/42)).** @markmokrenko отчёт: после стандартной установки на Yota и Tele2 подключение не проходит, на Beeline работает. Диагноз: проблема в `Jmin`/`Jmax`. Это продолжение Discussion #38 — мобильные операторы чувствительны к размеру junk-пакетов. Снизили `Jmax` offset с `Jmin+100..500` до `Jmin+50..250`, максимальный размер junk-пакета упал с ~590 до ~340 байт. Обфускация сохранена, совместимость с мобильными улучшается.

### Тесты

- **4 новых bats-теста** для `restore_backup` tar-валидации: happy path (good backup), absolute path rejection, path traversal rejection, server key `chmod 600`. Всего **85 bats-тестов**, все PASS.

### Live VPS-тесты

Релиз проверен на чистом Ubuntu 24.04 LTS: 13/13 проверок пройдено. Tar-валидация отработала на трёх типах атак — path traversal, абсолютные пути, symlinks. Проверка SHA256 verify_sha256 отработала на корректной и некорректной hash. UFW routing cleanup при `--uninstall` подтверждён.

> 📣 **Основной relnotes пакет для ветки 5.8.x** — в [v5.8.0 release notes](https://github.com/bivlked/amneziawg-installer/releases/tag/v5.8.0). v5.8.3 — hotfix поверх 5.8.2 с security hardening и Jmax range для мобильных сетей.

---

## [5.8.2] — 2026-04-10

### Исправлено

- **VNC-консоль хостера ломалась, потеря сети на Hetzner (Discussion #41):** `rp_filter` снижен с `1` (strict) до `2` (loose). Strict mode ломал routing на облачных хостерах (Hetzner и подобных) где шлюз в другой подсети. Добавлен `kernel.printk = 3 4 1 3` для подавления kernel warning messages в VNC-консоли. Спасибо @z036.
- **`--uninstall` теперь корректно удаляет UFW routing rules:** добавлено `out on <nic>` при удалении — UFW требует полное совпадение с правилом которое было создано при установке.
- **Дефолтный `Jc` снижен с 4-8 до 3-6 (Discussion #38):** мобильные сети (LTE/5G) плохо переносят большое количество junk-пакетов. @elvaleto подтвердил что `Jc=3` стабильно работает на Таттелеком (Летай).

### Документация

- **ADVANCED.md/en FAQ:** добавлены 2 новых entry — рекомендация Jc/I1 для мобильных сетей и workaround для VNC/Hetzner rp_filter проблемы. Таблица параметров обновлена: `Jc` диапазон `4-8 → 3-6`.

---

## [5.8.1] — 2026-04-09

Точечный hotfix v5.8.0 по мотивам [Discussion #40](https://github.com/bivlked/amneziawg-installer/discussions/40) от @z036: рандомизированные H1-H4 из v5.8.0 попадали в диапазон [2^31, 2^32-1], который клиент `amneziawg-windows-client` подчёркивает как невалидный и не даёт сохранять правки конфига. Сервер (amneziawg-go) полный `uint32` принимает, проблема только в UI-валидаторе клиента.

### Исправлено

- **H1-H4 Windows client compatibility ([Discussion #40](https://github.com/bivlked/amneziawg-installer/discussions/40)):** `generate_awg_h_ranges` теперь ограничивает верхний bound значений на `2^31-1 = 2147483647` вместо полного `uint32`. Это совместимо с `isValidHField()` в [amnezia-vpn/amneziawg-windows-client#85](https://github.com/amnezia-vpn/amneziawg-windows-client/issues/85) (upstream баг, открыт с февраля 2026, не исправлен). Реализация: bit-маска `0x7FFFFFFF` на выходе `od -N32 -tu4 /dev/urandom` плюс `rand_range 0 2147483647` в fallback-пути. Смещения нет — каждый младший бит остаётся независимым. Обфускация не слабеет: 4 непересекающиеся пары в `[0, 2^31)` с минимальной шириной 1000 каждая дают астрономическое количество возможных комбинаций, ТСПУ по дефолтам не зафингерпринтит. Спасибо @z036 за точный скриншот с подсвеченными полями.

### Совместимость

- **Существующие установки v5.8.0 продолжают работать на сервере.** `amneziawg-go` принимает полный `uint32`, handshake с клиентами не ломается. Единственное неудобство — редактор конфигов в `amneziawg-windows-client` подчёркивает H2-H4 красным, если они случайно попали в верхнюю половину диапазона (~99.6% новых v5.8.0 установок). Кросс-платформенный `amnezia-client` (Qt, Android/iOS/Desktop) этого ограничения не имеет.
- **Апгрейд с v5.8.0 рекомендуется** если используешь `amneziawg-windows-client`: `sudo bash /root/awg/install_amneziawg.sh --uninstall --yes`, потом установка v5.8.1 заново. Новые H1-H4 будут в безопасной половине диапазона.
- **Алгоритм и формат конфига не изменились**, только пространство генерации. Никаких breaking changes для сервера или существующих клиентских `.conf`.

### Тесты

- `tests/test_h_ranges.bats` обновлён: верхняя граница проверки изменена с `2^32-1` на `2^31-1` + добавлен регрессионный тест на 20 запусков × 8 значений (160 samples) которые все должны быть ≤ 2147483647. Всего **81 bats-тест** (+1 от 5.8.0).

### Документация

- **ADVANCED.md/en FAQ**: добавлен entry про upstream баг `amneziawg-windows-client` с объяснением root cause, ссылками на upstream issue #85 и Discussion #40, тремя вариантами workaround для пользователей v5.8.0.

> 📣 **Основной relnotes пакет для ветки 5.8.x** — в [v5.8.0 release notes](https://github.com/bivlked/amneziawg-installer/releases/tag/v5.8.0). Там весь контекст Discussion #38 (ТСПУ fingerprint) и история нескольких раундов аудита кода. v5.8.1 — hotfix поверх 5.8.0, рекомендуется всем пользователям Windows-клиента.

---

## [5.8.0] — 2026-04-07

Крупное обновление безопасности и надёжности после нескольких последовательных аудитов кода. Причина minor bump вместо patch — накопился значительный объём breaking-semantics изменений в обработке конфигов, parameter source of truth, и обработке ошибок.

### Безопасность

- **ТСПУ-фингерпринт по дефолтным H1-H4 (Discussion #38):** Диапазоны H1-H4 в `generate_awg_params` были захардкожены одинаковыми для всех установок (`100000-800000`, `1000000-8000000`, ...). Российский DPI зафингерпринтил эту статическую сигнатуру — установки переставали работать через мобильных операторов РФ. H1-H4 теперь рандомизируются при каждой установке: 8 случайных uint32 значений сортируются и группируются в 4 непересекающиеся пары. Каждая установка получает уникальные диапазоны без статической сигнатуры. Спасибо @Klavishnik (отчёт) и @elvaleto (диагностика).

- **Split-brain prevention в `load_awg_params`:** Если live `awg0.conf` существует, он теперь ЕДИНСТВЕННЫЙ источник истины для AWG протокольных параметров. Частично повреждённый live-конфиг (пропавшее поле H4 например) даёт explicit error с return 1 вместо тихого fallback на устаревшие значения из init-файла. Это закрывает класс split-brain багов, когда сервер живёт по одному конфигу, а `regen` выпускает клиентам другой набор J*/S*/H*.

- **Atomic export в `load_awg_params_from_server_conf`:** Парсер больше не экспортирует `AWG_*` по мере нахождения полей. Теперь либо все 11 обязательных полей успешно прочитаны и экспортированы, либо environment не модифицируется вообще. Защищает от mixed state при повреждённом `awg0.conf`.

- **`restore_backup` форсирует `chmod 600` на восстановленных серверных ключах** вместо наследования mode из архива через `cp -a`. Защищает от восстановления ключей с неправильными правами если backup был создан с поломанной umask.

- **`--uninstall` больше не отключает UFW глобально** (HIGH severity, audit). Раньше `ufw --force disable` убивал весь firewall на VPS где UFW использовался для SSH/web hardening ДО установки нашего скрипта. Теперь installer записывает маркер `.ufw_enabled_by_installer` только если ДО установки UFW был inactive, и uninstall отключает UFW только при наличии маркера. Backwards compat: старые установки без маркера получают safer-by-default — UFW продолжит работать.

- **Process-wide lock в установщике** (audit). Два concurrent запуска `install_amneziawg.sh --yes` могли читать одинаковый `setup_state`, конкурентно дёргать `apt-get` и ломать package state. Теперь `flock -n` на `$AWG_DIR/.install.lock` берётся в начале main() на весь lifetime процесса — второй экземпляр получает `die "Другой installer уже запущен"`.

- **Валидация `--endpoint`** (audit). Раньше значение принималось verbatim и записывалось в init и client.conf без sanity check. Newline/кавычки в endpoint могли injectить лишние директивы в конфиги. Новая функция `validate_endpoint()` запрещает newline/CR/кавычки/backslash и требует формат FQDN / IPv4 / `[IPv6]`.

### Исправлено

- **`regen` не обновлял AWG-параметры в клиентских конфигах (#38):** `load_awg_params` читал AWG-параметры только из закешированного `/root/awg/awgsetup_cfg.init`, а не из актуального `/etc/amnezia/amneziawg/awg0.conf`. Если пользователь правил `awg0.conf` руками (например, для смены параметров обфускации), `regen` генерировал клиентские конфиги со старыми значениями. Теперь `load_awg_params` приоритетно читает live серверный конфиг, init-файл используется только как bootstrap fallback при первой установке. Добавлена новая функция `load_awg_params_from_server_conf`.

- **`manage add/remove` игнорировали exit code `apply_config`** (audit). При failure apply_config команды логировали "Конфигурация применена" и возвращали success — юзер видел "OK", хотя peer был applied только в конфиг, но не к live интерфейсу. Теперь caller проверяет return code, логирует actionable error с указанием на `systemctl status`, и устанавливает `_cmd_rc=1`.

- **`check_expired_clients` оставлял peer на live интерфейсе при ошибке apply** (audit). Если apply_config падал после удаления expired peer из state файлов — peer исчезал из expiry/, но оставался активным на интерфейсе до ручного перезапуска. Permanent stuck state. Теперь функция проверяет return code и возвращает 1 с actionable сообщением.

- **`--uninstall` удалял `/etc/fail2ban/jail.local` по эвристике** (audit). Раньше весь файл удалялся если содержал `banaction = ufw` — слишком широкий фильтр, мог снести чужой jail.local с custom jails. Блок удаления полностью убран, оставлено только `rm -f /etc/fail2ban/jail.d/amneziawg.conf` (наш собственный artefact).

- **`check_server` не проверял exit code `awg show`** (audit). Мог отрапортовать "Состояние OK" даже когда `awg` упал. Теперь `awg show awg0` вызывается с сохранением вывода и проверкой exit code.

- **`backup_configs`/`restore_backup` leak'или временные директории при SIGINT** (audit). `mktemp -d` использовался напрямую, а trap cleanup `_awg_cleanup` удалял только файлы. Добавлен helper `manage_mktempdir` с регистрацией в массиве и chained cleanup.

- **`add_peer_to_server` теперь берёт inner flock** для защиты при прямых вызовах не через `generate_client` (defense-in-depth, self-audit). Контракт "caller должен держать lock" был fragile.

- **`check_expired_clients` валидирует имя клиента** перед использованием в путях (defense-in-depth, self-audit). Раньше `name=$(basename "$efile")` использовался без валидации.

- **Имена backup файлов больше не содержат двоеточий**: `%F_%T` → `%F_%H-%M-%S`. Двоеточия несовместимы с FAT/NTFS при копировании backup на другой носитель.

- **`apply_config` имеет explicit `return 0` на success path** — убирает неопределённость exit code от `exec {fd}>&-`.

### Оптимизации

- **`generate_awg_h_ranges` делает один read из `/dev/urandom`** вместо 8 subprocess вызовов `rand_range`. `od -An -N32 -tu4 /dev/urandom` читает 32 байта = 8 uint32 значений за одну операцию. Fallback на `rand_range` если `/dev/urandom` недоступен.

### Тесты

- **80 bats-тестов** (+34 от baseline 5.7.12 / 46 тестов):
  - `test_h_ranges.bats` — 9 проверок генерации H1-H4
  - `test_load_awg_params.bats` — 14 проверок парсера awg0.conf, priority над init-файлом, split-brain prevention, atomic export, bootstrap path
  - `test_validate_endpoint.bats` — 14 проверок validate_endpoint (valid FQDN/IPv4/IPv6, reject newline/CR/quotes/space/backslash/empty)
- Все 46 существующих тестов (apply_config, IP allocation, parse_duration, peer management, safe_load_config, validate) продолжают PASS без регрессий.

### Документация

- **ADVANCED.md/en FAQ**: добавлен workflow "Ротация параметров обфускации при детектировании DPI" — как править `awg0.conf` + restart + regen, с указанием что с 5.8.0 regen читает live config.

---

## [5.7.12] — 2026-04-06

### Исправлено

- **Fail2Ban на Debian (Discussion #39):** На Debian 12/13 rsyslog не установлен — fail2ban падал без доступа к `/var/log/auth.log`. Добавлен `backend = systemd` и установка `python3-systemd` для Debian. Ubuntu продолжает использовать `backend = auto`.

---

## [5.7.11] — 2026-03-31

### Исправлено

- **regen портит Address на Debian/mawk (#31):** `\s` в awk (PCRE-расширение) не поддерживается mawk. Заменено на `[ \t]`. Также `grep -oP` для приватного ключа заменён на POSIX-совместимый `sed`.
- **regen теряет значения после modify (#31):** При перегенерации конфига пользовательские настройки (DNS, PersistentKeepalive, AllowedIPs), изменённые через `modify`, теперь сохраняются.
- **modify оставляет .bak файлы (#31):** Бэкап-файл удаляется после успешного изменения.
- **check не видит порт на Debian (#31):** `grep -qP` заменён на POSIX-совместимый `grep` во всех местах проверки порта.

---

## [5.7.10] — 2026-03-31

### Добавлено

- **Batch remove клиентов (#30):** `manage remove client1 client2 client3` — удаление нескольких клиентов одной командой с одним apply_config в конце.
- **AWG_SKIP_APPLY=1 (#30):** Переменная среды для пропуска apply_config. Позволяет накопить изменения и применить одной командой — для автоматизации и API-интеграций. Корректное сообщение "Применение отложено" вместо "Конфигурация применена".
- **flock в apply_config (#30):** Межпроцессная блокировка (`${AWG_DIR}/.awg_apply.lock`) предотвращает параллельные restart/syncconf вызовы.
- **Unit тесты (bats-core):** 43 теста для awg_common.sh — parse_duration, safe_load_config, IP allocation, peer management, apply_config modes, validate. CI workflow `.github/workflows/test.yml`.

---

## [5.7.9] — 2026-03-25

### Добавлено

- **Режим применения конфигурации (#30):** Новая опция `--apply-mode=restart` для `manage_amneziawg.sh`. Позволяет переключиться на полный перезапуск сервиса вместо `awg syncconf` — обходит upstream deadlock в модуле amneziawg ([amneziawg-linux-kernel-module#146](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/146)). Режим сохраняется в `awgsetup_cfg.init` (`AWG_APPLY_MODE=restart`).

---

## [5.7.8] — 2026-03-24

### Добавлено

- **Batch add клиентов (#29):** `manage add client1 client2 client3 ...` — создание нескольких клиентов одной командой. `awg syncconf` вызывается один раз в конце вместо N раз. Предотвращает kernel panic при массовом создании клиентов (upstream баг модуля [amneziawg-linux-kernel-module#146](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/146)).

---

## [5.7.7] — 2026-03-24

### Исправлено

- **Потеря клиентов при переустановке:** `render_server_config` перезаписывал `awg0.conf` с нуля. Существующие `[Peer]` блоки теперь автоматически восстанавливаются из бэкапа при повторном прогоне шага 6.
- **Race condition при добавлении клиентов (TOCTOU):** `get_next_client_ip` и `add_peer_to_server` теперь выполняются в одной критической секции (`flock` в `generate_client`). Два параллельных `add` больше не могут выбрать один и тот же IP.
- **Ложный успех `restore`:** `restore_backup` при ошибках копирования (server/clients/keys) теперь возвращает non-zero exit code вместо тихого «Восстановление завершено».
- **Парсер конфига и двойные кавычки:** `safe_load_config` теперь корректно обрабатывает значения в двойных кавычках (`"value"`) в дополнение к одинарным.

---

## [5.7.6] — 2026-03-24

### Исправлено

- **UFW блокирует VPN-трафик (Discussion #28):** Добавлено правило `ufw route allow in on awg0 out on <nic>` при настройке фаервола. Ранее default policy `deny (routed)` блокировала проброс пакетов awg0→eth0, несмотря на PostUp iptables правила. Правило автоматически удаляется при деинсталляции.
- **PostUp FORWARD ordering:** `iptables -A FORWARD` заменён на `iptables -I FORWARD` для приоритетной вставки правила в начало цепочки. Гарантирует корректную маршрутизацию при работе без UFW (`--no-tweaks`).

---

## [5.7.5] — 2026-03-20

### Исправлено

- **Trailing newlines в awg0.conf (#27):** После удаления пиров в серверном конфиге накапливались множественные пустые строки. Добавлена нормализация через `cat -s` при каждом remove.
- **Timeout для awg syncconf (#27):** `awg-quick strip` и `awg syncconf` теперь вызываются с `timeout 10`. При зависании (upstream deadlock [amneziawg-linux-kernel-module#146](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/146)) скрипт делает fallback на полный перезапуск сервиса вместо бесконечного ожидания.

---

## [5.7.4] — 2026-03-20

### Исправлено

- **MTU 1280 по умолчанию (Closes #26):** Серверный и клиентские конфиги теперь содержат `MTU = 1280`. Решает проблему подключения смартфонов через сотовые сети и iPhone.
- **Jmax cap:** Максимальный размер junk-пакетов ограничен `Jmin+500` (было `Jmin+999`). Предотвращает фрагментацию при MTU 1280.
- **validate_subnet:** Последний октет подсети должен быть 1 (адрес сервера). Ранее допускались произвольные значения, что приводило к конфликту с `get_next_client_ip`.
- **awg show dump parsing:** Пропуск interface line через `tail -n +2` вместо ненадёжной проверки пустого поля psk.
- **manage help без AWG:** `help` и пустая команда выводят справку до `check_dependencies`, позволяя использовать `--help` без установленного AWG.
- **help text:** Справка инсталлятора перечисляет все 4 поддерживаемые ОС (Ubuntu 24.04/25.10, Debian 12/13).
- **manage --expires help:** Добавлен формат `4w` в справку `--expires` (уже поддерживался парсером, но отсутствовал в тексте help).

### Улучшено

- **Кэш IP:** `get_server_public_ip()` кэширует результат — повторные вызовы (add/regen) не обращаются к внешним сервисам.
- **O(N) IP lookup:** `get_next_client_ip()` использует ассоциативный массив для поиска свободного IP вместо вложенных циклов O(N²).

### Документация

- Исправлена таблица совместимости клиентов: `amneziawg-windows-client >= 2.0.0` поддерживает AWG 2.0 (ранее ошибочно указано как AWG 1.x only).
- Исправлен APT-формат для Ubuntu 24.04: DEB822 `.sources` (было `.list`).
- Исправлен пример `restore` в FAQ миграции: корректный путь `/root/awg/backups/`.
- Исправлена ссылка на деинсталляцию в EN README FAQ: `install_amneziawg_en.sh`.
- Добавлен Ubuntu 25.10 в FAQ ответ «Какой хостинг подходит?».
- Обновлены примеры конфигов: добавлен `MTU = 1280`.
- Обновлён диапазон Jmax в таблице параметров: `+500` вместо `+999`.
- Переписана секция MTU: автоматический для v5.7.4+, ручной workaround для старых версий.
- Убран пункт «MTU не задан» из «Известных ограничений».
- Обновлён FAQ «Как изменить MTU?» для автоматического MTU.

---

## [5.7.3] — 2026-03-18

### Исправлено

- **Uninstall SSH lockout:** UFW отключается ДО unban fail2ban — предотвращает блокировку SSH при обрыве соединения во время деинсталляции.
- **CIDR валидация (strict):** Невалидный CIDR в `--route-custom` вызывает `die()` в CLI-режиме. В интерактивном — повторный запрос ввода. Ранее установка продолжалась с некорректными AllowedIPs.
- **validate_subnet .0/.255:** Подсети с последним октетом 0 (network address) или 255 (broadcast) отклоняются — ранее принимались.
- **ALLOWED_IPS resume:** При возобновлении установки из конфига валидируются пользовательские CIDR (mode=3) — ранее загружались без проверки.
- **modify sed mismatch:** Синхронизирован паттерн sed с grep в `modify_client()` — обрабатывает .conf с любым форматированием пробелов вокруг `=`. Добавлена постпроверка замены.
- **--no-color ANSI leak:** Устранена утечка ESC-кодов `\033[0m` в вывод `list --no-color`.
- **Uninstall wildcard cleanup:** Удалены бессмысленные wildcard-паттерны из uninstall — файлы `*amneziawg*` в `/etc/cron.d/` и `/usr/local/bin/` никогда не создавались.

### Документация

- Добавлен AmneziaWG for Windows 2.0.0 как поддерживаемый клиент.
- Удалено ошибочное примечание о необходимости curl на Debian.

---

## [5.7.2] — 2026-03-16

### Безопасность

- **safe_load_config():** Замена `source` на whitelist-парсер конфигурации в `awg_common.sh` — только разрешённые ключи (AWG_*, OS_*, DISABLE_IPV6 и др.) загружаются из файла. Устраняет потенциальную инъекцию кода через `awgsetup_cfg.init`.
- **Supply chain pinning:** URL скачивания скриптов привязаны к тегу версии (`AWG_BRANCH=v${SCRIPT_VERSION}`) вместо `main`. Переменная `AWG_BRANCH` доступна для переопределения при разработке.
- **HTTPS для IP-детекции:** `get_server_public_ip()` использует HTTPS вместо HTTP для определения внешнего IP.

### Исправлено

- **modify allowlist:** Убраны Address и MTU из допустимых параметров `modify` — эти параметры управляются инсталлятором и не должны изменяться вручную.
- **flock для add/remove peer:** Операции добавления и удаления пиров защищены `flock -x` для предотвращения race condition при параллельных вызовах.
- **cron expiry env:** Cron-задача expiry явно задаёт PATH и использует `--conf-dir` для корректной работы в минимальном cron-окружении.
- **log_warn для malformed expiry:** Некорректные файлы истечения обрабатываются через `log_warn` вместо тихого пропуска.
- **Мёртвый код:** Удалены неиспользуемые функции и переменные из `awg_common.sh`.

### Улучшено

- **list_clients O(N):** Оптимизация `list_clients` — однопроходный алгоритм вместо O(N*M).
- **backup/restore:** Бэкапы теперь включают данные истечения клиентов (`expiry/`) и cron-задачу.
- **Версия:** 5.7.1 → 5.7.2 во всех скриптах.

---

## [5.7.1] — 2026-03-13

### Исправлено

- **vpn:// URI AllowedIPs:** `generate_vpn_uri()` использовала захардкоженный `0.0.0.0/0` вместо реальных AllowedIPs из клиентского конфига — split-tunnel конфигурации теперь корректно передаются в URI.
- **Fail2Ban jail.d:** Установка теперь пишет в `/etc/fail2ban/jail.d/amneziawg.conf` вместо перезаписи `jail.local` — пользовательские настройки Fail2Ban сохраняются.
- **Fail2Ban uninstall:** Деинсталляция удаляет только свои артефакты вместо `rm -rf /etc/fail2ban/`.
- **validate_client_name:** Валидация имени клиента добавлена в команды `remove` и `modify` — ранее работала только для `add` и `regen`.
- **exit code:** Скрипт управления теперь возвращает корректный код ошибки вместо безусловного `exit 0`.
- **expiry cron path:** Cron-задача expiry использует `$AWG_DIR` вместо захардкоженного `/root/awg/`.

### Удалено

- **rand_range():** Удалена неиспользуемая функция из `awg_common.sh` (инсталлятор определяет свою копию).

---

## [5.7.0] — 2026-03-13

### Добавлено

- **syncconf:** Команды `add` и `remove` автоматически применяют изменения через `awg syncconf` — zero-downtime, без разрыва активных соединений (#19).
- **apply_config():** Новая функция в `awg_common.sh` — применяет конфиг через `awg syncconf` с fallback на полный перезапуск.
- **--no-tweaks:** Флаг для инсталлятора — пропускает hardening (UFW, Fail2Ban, sysctl tweaks, cleanup) для опытных пользователей с уже настроенными серверами (#21).
- **setup_minimal_sysctl():** Минимальная настройка sysctl при `--no-tweaks` — только `ip_forward` и IPv6.

### Исправлено

- **trap конфликт:** Устранена перезапись обработчика EXIT при подключении `awg_common.sh` через `source`. Теперь каждый скрипт владеет своим trap и цепляет cleanup библиотеки явно.

### Изменено

- **Expiry cleanup:** Авто-удаление истёкших клиентов теперь использует `syncconf` вместо полного перезапуска.
- **Manage help:** Убрано предупреждение о ручном перезапуске после `add`/`remove` (больше не требуется).
- **Версия:** 5.6.0 → 5.7.0 во всех скриптах.

---

## [5.6.0] — 2026-03-13

### Добавлено

- **stats:** Команда `stats` — статистика трафика по клиентам (format_bytes через awk).
- **stats --json:** Машиночитаемый JSON-вывод для интеграции и мониторинга.
- **--expires:** Флаг `--expires=ВРЕМЯ` для `add` — клиенты с ограниченным сроком действия (1h, 12h, 1d, 7d, 30d, 4w).
- **Система истечения:** Авто-удаление клиентов через cron (`/etc/cron.d/awg-expiry`, проверка каждые 5 мин).
- **vpn:// URI:** Генерация `.vpnuri` файлов для импорта в Amnezia Client (zlib-сжатие через Perl).
- **Debian 12 (bookworm):** Полная поддержка — PPA через маппинг codename на focal.
- **Debian 13 (trixie):** Полная поддержка — PPA через маппинг codename на noble, DEB822 формат.
- **linux-headers fallback:** Авто-fallback на `linux-headers-$(dpkg --print-architecture)` для Debian.

### Исправлено

- **JSON sanitization:** Безопасная сериализация в JSON-выводе.
- **Numeric quoting:** Числовые параметры AWG в кавычках для корректной обработки.
- **O(n) stats:** Single-pass сбор статистики вместо множественных вызовов.
- **backup filename:** `%F_%T` → `%F_%H%M%S` (убраны двоеточия из имени файла).
- **cron auto-remove:** Очистка cron при удалении последнего expiry-клиента.
- **backups perms:** `chmod 700` после `mkdir` для директории бэкапов.
- **apt sources location:** Бэкап apt sources в `$AWG_DIR` вместо `sources.list.d`.
- Множественные мелкие исправления по code review (19 фиксов).

### Изменено

- **Debian-aware installer:** Определение OS_ID, адаптивное поведение (cleanup, PPA, headers).
- **Версия:** 5.5.1 → 5.6.0 во всех скриптах.

---

## [5.5.1] — 2026-03-05

### Исправлено

- **read -r:** Добавлен флаг `-r` ко всем `read -p` (15 мест) — предотвращает интерпретацию `\` как escape-символа при пользовательском вводе.
- **curl timeout:** Добавлены `--max-time 60 --retry 2` к скачиванию скриптов при установке — предотвращает бесконечное зависание при проблемах с сетью.
- **subnet validation:** Валидация подсети теперь проверяет каждый октет ≤ 255 — ранее пропускала адреса вроде `999.999.999.999/24`.
- **chmod checks:** Добавлена проверка ошибок `chmod 600` при установке прав на файлы ключей.
- **pipe subshell:** Исправлена потеря переменных в цикле регенерации конфигов из-за pipe subshell — заменён на here-string.
- **port grep:** Улучшена точность поиска порта в `ss -lunp` — замена `grep ":PORT "` на `grep -P ":PORT\s"` для исключения ложных совпадений.
- **sed → bash:** Замена `sed 's/%/%%/g'` на `${msg//%/%%}` — убраны 2 лишних subprocess'а на каждый вызов лога.
- **cleanup trap:** Добавлен `trap EXIT` для автоматической очистки временных файлов инсталлятора.

---

## [5.5] — 2026-03-02

### Исправлено

- **uninstall:** Деинсталляция выполнялась без подтверждения при недоступном `/dev/tty` (pipe, cron, non-TTY SSH) из-за дефолтного `confirm="yes"`.
- **uninstall:** Модуль ядра `amneziawg` оставался загруженным после деинсталляции — добавлен `modprobe -r`.
- **uninstall:** Рабочая директория `/root/awg/` пересоздавалась логированием после удаления — перенесена очистка в конец.
- **uninstall:** Пустая `/etc/fail2ban/` и бэкапы PPA `.bak-*` оставались после деинсталляции.
- **--no-color:** Escape-код сброса `\033[0m` не подавлялся при `--no-color` — исправлена инициализация `color_end`.
- **step99:** Дублирующееся сообщение «Очистка apt…» — убран лишний вызов `log` перед `cleanup_apt()`.
- **step99:** Lock-файл `setup_state.lock` не удалялся после завершения установки.
- **manage:** Непоследовательная орфография «удален»/«удалён» — унифицировано.

---

## [5.4] — 2026-03-02

### Исправлено

- **step5:** Ошибка скачивания `manage_amneziawg.sh` теперь фатальна (`die`), как и для `awg_common.sh`.
- **update_state():** `die()` внутри flock-subshell не завершал основной процесс — перенесён наружу.
- **step6:** Бэкап серверного конфига теперь создаётся *до* `render_server_config`, а не после перезаписи.
- **cloud-init:** Консервативная детекция — маркеры cloud-init проверяются первыми, чтобы не удалить его на cloud-хостах.
- **restore_backup():** Добавлена защита от зависания в неинтерактивном режиме (требуется путь к файлу).
- **Подсеть:** Валидация теперь разрешает только маску `/24` (соответствует фактической логике аллокации IP).
- **Версия:** Устранены артефакты `v5.1` в логах и диагностике; введена константа `SCRIPT_VERSION`.

---

## [5.3] — 2026-03-02

### Добавлено

- **Английские скрипты:** Полные английские версии всех трёх скриптов (`install_amneziawg_en.sh`, `manage_amneziawg_en.sh`, `awg_common_en.sh`) с переведёнными сообщениями, справкой и комментариями.
- **CI:** ShellCheck и `bash -n` проверки для английских скриптов.
- **PR template:** Чеклист-пункт синхронизации EN/RU версий.
- **CONTRIBUTING.md:** Требование синхронизации EN/RU при изменении скриптов.

---

## [5.2] — 2026-03-02

### Исправлено

- **check_server():** Исправлен инвертированный exit code (return 1 при успехе → return 0).
- **Диагностика restart/restore:** Вывод `systemctl status` теперь корректно попадает в лог.
- **restore_backup():** Путь восстановления серверного конфига теперь берётся из `$SERVER_CONF_FILE`.

### Улучшено

- **awg_mktemp():** Активирована автоочистка временных файлов через trap EXIT.
- **modify:** Добавлен allowlist допустимых параметров (DNS, Endpoint, AllowedIPs, Address, PersistentKeepalive, MTU). *(Address и MTU убраны в v5.7.2)*
- **Документация:** Убрано некорректное упоминание поддержки подсети /16.
- Удалён мёртвый trap-код из install_amneziawg.sh.

---

## [5.1] — 2026-03-01

### Исправлено

- **CRITICAL:** Command injection через спецсимволы `#`, `&`, `/`, `\` в `modify_client()` — добавлена функция `escape_sed()` для экранирования.
- **CRITICAL:** Race condition в `update_state()` — добавлена блокировка через `flock -x`.
- **MEDIUM:** `curl` в `get_server_public_ip()` мог получить HTML вместо IP — добавлен флаг `-f` (fail on error) и очистка whitespace.
- **MEDIUM:** Fallback `$RANDOM` в `rand_range()` давал макс. 32767 вместо uint32 — заменён на `(RANDOM<<15|RANDOM)` для 30-битного диапазона.
- **MEDIUM:** Pipe subshell в `check_server()` — заменён на process substitution `< <(...)`.
- **MEDIUM:** Awk-скрипт `remove_peer_from_server()` не обрабатывал нестандартные секции — добавлена обработка любых `[...]` блоков.

### Добавлено

- **CI:** GitHub Actions workflow — ShellCheck + `bash -n` на push/PR к main.
- **GitHub:** Issue templates (bug report, feature request) в формате YAML-форм.
- **GitHub:** PR template с чеклистом (bash -n, shellcheck, VPS test, changelog).
- **SECURITY.md:** Политика безопасности, ответственное раскрытие уязвимостей.
- **CONTRIBUTING.md:** Гайд для контрибьюторов с требованиями к коду и тестированию.
- **.editorconfig:** Единые настройки форматирования (UTF-8, LF, отступы).
- **Trap cleanup:** Автоматическая очистка временных файлов через `trap EXIT` + `awg_mktemp()`.
- **Bash version check:** Проверка `Bash >= 4.0` в начале install и manage скриптов.
- **Документация:** Примеры конфигов, Mermaid-диаграмма архитектуры, расширенный FAQ, troubleshooting.

### Изменено

- **Версия:** 5.0 → 5.1 во всех скриптах и документации.
- **README.md:** Таблица команд расширена до 10 (+ modify, backup, restore), FAQ до 8 вопросов.
- **ADVANCED.md:** Добавлены примеры конфигов, команд manage, описание диагностики, инструкция обновления.

---

## [5.0] — 2026-03-01

### ⚠️ Breaking Changes

- **Протокол AWG 2.0** несовместим с AWG 1.x. Все клиенты должны обновить конфигурацию.
- Требуется клиент **Amnezia VPN >= 4.8.12.7** с поддержкой AWG 2.0.
- Предыдущая версия доступна в ветке [`legacy/v4`](https://github.com/bivlked/amneziawg-installer/tree/legacy/v4).

### Добавлено

- **AWG 2.0:** Полная поддержка протокола — параметры H1-H4 (диапазоны), S1-S4, CPS (I1).
- **Нативная генерация:** Все ключи и конфиги генерируются средствами Bash + `awg` без внешних зависимостей.
- **awg_common.sh:** Общая библиотека функций для install и manage скриптов.
- **Очистка сервера:** Автоматическое удаление ненужных пакетов (snapd, modemmanager, networkd-dispatcher, unattended-upgrades и др.).
- **Hardware-aware оптимизация:** Автоматическая настройка swap, сетевых буферов и sysctl на основе характеристик сервера (RAM, CPU, NIC).
- **Оптимизация NIC:** Отключение GRO/GSO/TSO offloads для стабильной работы VPN-туннеля.
- **Расширенный sysctl hardening:** Адаптивные сетевые буферы, conntrack, дополнительная защита.
- **Регенерация отдельных клиентов:** Команда `regen <имя>` для перегенерации конфигов одного клиента.
- **Валидация AWG 2.0:** Проверка наличия всех параметров протокола в серверном конфиге.
- **AWG 2.0 диагностика:** Команда `check` показывает статус параметров AWG 2.0.

### Удалено

- **Python/venv/awgcfg.py:** Полностью убрана зависимость от Python и внешнего генератора конфигов.
- **Workaround для бага awgcfg.py:** Больше не требуется перемещение `awgsetup_cfg.init` при генерации.
- **Параметры j1-j3, itime:** Устаревшие параметры AWG 1.x больше не поддерживаются.

### Изменено

- **Архитектура:** 2 файла → 3 файла (install + manage + awg_common.sh).
- **Шаг 1 установки:** Добавлена системная очистка и оптимизация.
- **Шаг 2 установки:** Устанавливается `qrencode` вместо Python.
- **Шаг 5 установки:** Скачиваются `awg_common.sh` + `manage` (без Python/venv).
- **Шаг 6 установки:** Полностью нативная генерация конфигов.
- **Генерация ключей:** Нативная через `awg genkey` / `awg pubkey`.
- **QR-коды:** Генерация через `qrencode` напрямую (без Python).
- **Документация:** README.md и ADVANCED.md обновлены для AWG 2.0.

---

## [4.0] — 2025-07-15

### Добавлено

- Поддержка AWG 1.x (Jc, Jmin, Jmax, S1, S2, H1-H4 фиксированные).
- Установка через DKMS.
- Генерация конфигов через Python + awgcfg.py.
- Управление клиентами: add, remove, list, regen, modify, backup, restore.
- UFW firewall, Fail2Ban, sysctl hardening.
- Поддержка возобновления установки после перезагрузки.
- Диагностический отчет (`--diagnostic`).
- Полная деинсталляция (`--uninstall`).

[Unreleased]: https://github.com/bivlked/amneziawg-installer/compare/v5.10.1...HEAD
[5.10.1]: https://github.com/bivlked/amneziawg-installer/compare/v5.10.0...v5.10.1
[5.10.0]: https://github.com/bivlked/amneziawg-installer/compare/v5.9.0...v5.10.0
[5.9.0]: https://github.com/bivlked/amneziawg-installer/compare/v5.8.4...v5.9.0
[5.8.4]: https://github.com/bivlked/amneziawg-installer/compare/v5.8.3...v5.8.4
[5.8.3]: https://github.com/bivlked/amneziawg-installer/compare/v5.8.2...v5.8.3
[5.8.2]: https://github.com/bivlked/amneziawg-installer/compare/v5.8.1...v5.8.2
[5.8.1]: https://github.com/bivlked/amneziawg-installer/compare/v5.8.0...v5.8.1
[5.8.0]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.12...v5.8.0
[5.7.12]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.11...v5.7.12
[5.7.11]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.10...v5.7.11
[5.7.10]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.9...v5.7.10
[5.7.9]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.8...v5.7.9
[5.7.8]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.7...v5.7.8
[5.7.7]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.6...v5.7.7
[5.7.6]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.5...v5.7.6
[5.7.5]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.4...v5.7.5
[5.7.4]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.3...v5.7.4
[5.7.3]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.2...v5.7.3
[5.7.2]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.1...v5.7.2
[5.7.1]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.0...v5.7.1
[5.7.0]: https://github.com/bivlked/amneziawg-installer/compare/v5.6.0...v5.7.0
[5.6.0]: https://github.com/bivlked/amneziawg-installer/compare/v5.5.1...v5.6.0
[5.5.1]: https://github.com/bivlked/amneziawg-installer/compare/v5.5...v5.5.1
[5.5]: https://github.com/bivlked/amneziawg-installer/compare/v5.4...v5.5
[5.4]: https://github.com/bivlked/amneziawg-installer/compare/v5.3...v5.4
[5.3]: https://github.com/bivlked/amneziawg-installer/compare/v5.2...v5.3
[5.2]: https://github.com/bivlked/amneziawg-installer/compare/v5.1...v5.2
[5.1]: https://github.com/bivlked/amneziawg-installer/compare/v5.0...v5.1
[5.0]: https://github.com/bivlked/amneziawg-installer/compare/v4.0...v5.0
[4.0]: https://github.com/bivlked/amneziawg-installer/releases/tag/v4.0

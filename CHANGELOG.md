# Changelog

Все заметные изменения в проекте документируются в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/).

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

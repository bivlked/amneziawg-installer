![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04-orange)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://github.com/bivlked/amneziawg-installer/blob/main/LICENSE)
![Status](https://img.shields.io/badge/Status-Stable-success)
[![Version](https://img.shields.io/badge/Installer_Version-5.1-blue)](https://github.com/bivlked/amneziawg-installer/releases)
![AWG 2.0](https://img.shields.io/badge/AmneziaWG-2.0-blueviolet)
[![ShellCheck](https://github.com/bivlked/amneziawg-installer/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/bivlked/amneziawg-installer/actions/workflows/shellcheck.yml)

<h1 align="center">Автоматическая установка и управление AmneziaWG 2.0</h1>

<p align="center">
  Набор Bash-скриптов для быстрой, безопасной и удобной установки,<br>
  настройки и управления VPN-сервером <strong>AmneziaWG 2.0</strong> на <strong>Ubuntu 24.04 LTS Minimal</strong>.
</p>

<p align="center">
  <a href="#vozmozhnosti">Возможности</a> •
  <a href="#trebovaniya">Требования</a> •
  <a href="#recomend-hosting">Хостинг</a> •
  <a href="#ustanovka">Установка</a> •
  <a href="#upravlenie">Управление</a> •
  <a href="#migratsiya">Миграция с v4</a> •
  <a href="#dopolnitelno">Дополнительно</a> •
  <a href="#faq-main">FAQ</a> •
  <a href="#licenziya">Лицензия</a>
</p>

---

<a id="vozmozhnosti"></a>
## ✨ Возможности

* 🚀 **AmneziaWG 2.0:** Полная поддержка протокола AWG 2.0 с параметрами обфускации H1-H4 (диапазоны), S1-S4, CPS (I1).
* 🔧 **Нативная генерация:** Все ключи и конфиги генерируются средствами Bash + `awg` без внешних зависимостей (Python/awgcfg.py убраны).
* 🧹 **Оптимизация сервера:** Автоматическая очистка ненужных пакетов (snapd, modemmanager и др.), hardware-aware оптимизация (swap, NIC, sysctl).
* 🔄 **Возобновляемость:** Установку можно безопасно прерывать (для перезагрузок) и возобновлять.
* 🔒 **Безопасность по умолчанию:** UFW с лимитами SSH, отключение IPv6 (опц.), безопасные права доступа, Harden sysctl, Fail2Ban.
* ⚙️ **Надежность:** Установка через DKMS, проверка зависимостей и статуса модуля ядра.
* 🎛️ **Гибкость:** Выбор порта, подсети, режима IPv6 и маршрутизации при установке. Поддержка `--endpoint` для серверов за NAT.
* 🧑‍💻 **Управление:** Удобный скрипт `manage_amneziawg.sh` для работы с клиентами и сервером.
* 🩺 **Диагностика:** Подробный отчет с AWG 2.0 параметрами (`--diagnostic`).
* 🗑️ **Деинсталляция:** Полное удаление (`--uninstall`).
* 📝 **Логирование:** Запись всех действий в лог-файлы в `/root/awg/`.

---

<a id="trebovaniya"></a>
## 🖥️ Требования

* **ОС:** **Чистая** установка **Ubuntu Server 24.04 LTS Minimal**.
* **Доступ:** Права `root` (через `sudo`).
* **Интернет:** Стабильное подключение.
* **Ресурсы:** ~1 ГБ ОЗУ (рекомендуется 2+ ГБ), ~3 ГБ диска.
* **SSH:** Доступ по SSH.
* **Клиент:** Amnezia VPN **>= 4.8.12.7** с поддержкой AWG 2.0.
    > ⚠️ **ВАЖНО:** Если используется **нестандартный порт SSH** (отличный от 22), **ОБЯЗАТЕЛЬНО** добавьте правило `sudo ufw allow ВАШ_ПОРТ/tcp` **ДО** запуска скрипта установки!

---

<a id="recomend-hosting"></a>
## 🚀 Рекомендация хостинга

Для стабильной работы VPN-сервера с высокой пропускной способностью важен надежный хостинг с хорошим каналом.

Мы протестировали и рекомендуем [**FreakHosting**](https://freakhosting.com/clientarea/aff.php?aff=392). В частности, их линейка **BUDGET VPS** предлагает отличное соотношение цены и качества.

Их IP-адреса не идентифицируются, как адреса датацентров и через них прекрасно работают такие сервисы, как Claude Desktop и другие (в отличии, например, от Azure, чьи адреса Claude теперь блокирует).

* **Рекомендуемый тариф:** **BVPS-2**
* **Характеристики:** 2 vCPU, 2 GB RAM, 40 GB NVMe SSD.
* **Ключевое преимущество:** порт **10 Gbps** с **неограниченным трафиком**. Идеально для VPN!
* **Цена:** Всего **€25 в год** (около 2200 руб.).

Этой конфигурации более чем достаточно для комфортной работы AmneziaWG с большим количеством подключений и высоким трафиком.

---

<a id="ustanovka"></a>
## 🔧 Установка (Рекомендуемый способ)

Этот метод установки гарантирует корректную работу интерактивных запросов и цветного вывода в вашем терминале.

1.  **Подключитесь** к **чистому** серверу Ubuntu 24.04 по SSH.
    > **Совет:** После создания сервера подождите 5-10 минут, чтобы завершились все фоновые процессы инициализации системы, прежде чем запускать установку.

2.  **Скачайте скрипт:**
    ```bash
    wget https://raw.githubusercontent.com/bivlked/amneziawg-installer/main/install_amneziawg.sh
    ```
3.  **Сделайте его исполняемым:**
    ```bash
    chmod +x install_amneziawg.sh
    ```
4.  **Запустите с `sudo`:**
    ```bash
    sudo bash ./install_amneziawg.sh
    ```
    *(Вы также можете передать параметры командной строки, см. `sudo bash ./install_amneziawg.sh --help` или [ADVANCED.md#cli-params-adv](ADVANCED.md#cli-params-adv))*

5.  **Начальная настройка:** Скрипт интерактивно запросит:
    * **UDP порт:** Порт для подключения клиентов (1024-65535). По умолчанию: `39743`.
    * **Подсеть туннеля:** Внутренняя сеть для VPN. По умолчанию: `10.9.9.1/24`.
    * **Отключение IPv6:** Рекомендуется отключить (`Y`) для избежания утечек трафика.
    * **Режим маршрутизации:** Определяет, какой трафик пойдет через VPN. По умолчанию `2` (Список Amnezia+DNS) - рекомендуется для лучшей совместимости и обхода блокировок.

    Параметры AWG 2.0 (Jc, S1-S4, H1-H4, I1) генерируются **автоматически** — никаких действий не требуется.

6.  **Перезагрузки:** Потребуется **ДВЕ** перезагрузки. Скрипт запросит подтверждение `[y/N]`. Введите `y` и нажмите Enter.

7.  **Продолжение:** После каждой перезагрузки **снова запустите скрипт** той же командой:
    ```bash
    sudo bash ./install_amneziawg.sh
    ```
    Скрипт автоматически продолжит с нужного шага **без повторных запросов**.

8.  **Завершение:** После второй перезагрузки и третьего запуска скрипта вы увидите сообщение:
    `Установка и настройка AmneziaWG 2.0 УСПЕШНО ЗАВЕРШЕНА!`

**Расположение файлов:**

* Рабочая директория, логи, файлы клиентов: `/root/awg/`
* Конфигурация сервера: `/etc/amnezia/amneziawg/awg0.conf`
* Файл настроек скрипта: `/root/awg/awgsetup_cfg.init`
* Скрипт управления: `/root/awg/manage_amneziawg.sh`
* Общие функции: `/root/awg/awg_common.sh`

---

<a id="upravlenie"></a>
## 👥 Управление клиентами (`manage_amneziawg.sh`)

Скрипт `manage_amneziawg.sh` для управления пользователями скачивается автоматически.

**Использование:**

```bash
sudo bash /root/awg/manage_amneziawg.sh <команда> [аргументы]
```

**Основные команды:** (Полный список см. `... help` или [ADVANCED.md#manage-commands-adv](ADVANCED.md#manage-commands-adv))

| Команда   | Аргументы              | Описание                     | Перезапуск? |
| :-------- | :--------------------- | :--------------------------- | :-----------: |
| `add`     | `<имя_клиента>`        | Добавить клиента             |      **Да** |
| `remove`  | `<имя_клиента>`        | Удалить клиента              |      **Да** |
| `list`    | `[-v]`                 | Список клиентов (`-v` детали) |       Нет     |
| `regen`   | `[имя_клиента]`        | Переген. файлы (всех/одного) |       Нет     |
| `modify`  | `<имя> <пар> <зн>`     | Изменить параметр клиента    |       Нет     |
| `backup`  |                        | Создать резервную копию      |       Нет     |
| `restore` | `[файл]`               | Восстановить из резервной копии |    Нет     |
| `show`    |                        | Статус `awg show`            |       Нет     |
| `check`   |                        | Проверка состояния сервера     |       Нет     |
| `restart` |                        | Перезапуск сервиса AmneziaWG   |       -       |

> **❗️ ВАЖНО:** После `add`, `remove` **перезапустите сервис**: `sudo systemctl restart awg-quick@awg0` (или используйте команду `restart` скрипта управления).

**Получение файлов клиентов:** Файлы `.conf` и `.png` находятся в `/root/awg/`. Используйте `scp`, `sftp` или любой другой безопасный способ для их копирования.

---

<a id="migratsiya"></a>
## 🔄 Миграция с v4.0

> **v5.0 — это breaking change.** Протокол AWG 2.0 **несовместим** с AWG 1.x. Все клиенты должны обновить конфигурацию.

**Порядок миграции:**

1. **Бэкап:** `sudo bash /root/awg/manage_amneziawg.sh backup`
2. **Деинсталляция v4:** `sudo bash ./install_amneziawg.sh --uninstall`
3. **Установка v5.0:** скачайте новый скрипт и установите (см. [Установка](#ustanovka))
4. **Добавьте клиентов:** `sudo bash /root/awg/manage_amneziawg.sh add <имя>`
5. **Обновите клиенты:** установите Amnezia VPN **>= 4.8.12.7** и импортируйте новые `.conf`

**Что изменилось:**

| | v4.0 (AWG 1.x) | v5.0 (AWG 2.0) |
|---|---|---|
| Протокол | AWG 1.x (H1-H4 фиксированные) | AWG 2.0 (H1-H4 диапазоны, S3-S4, CPS I1) |
| Генерация конфигов | Python + awgcfg.py | Нативный Bash + `awg genkey/pubkey` |
| Зависимости | Python 3 + venv | Только Bash + qrencode |
| Оптимизация сервера | Нет | Cleanup + hardware-aware tuning |
| Архитектура скриптов | 2 файла | 3 файла (+ awg_common.sh) |

Предыдущая версия доступна в ветке [`legacy/v4`](https://github.com/bivlked/amneziawg-installer/tree/legacy/v4).

---

<a id="dopolnitelno"></a>
## ℹ️ Дополнительная информация

Более подробную информацию о деталях конфигурации, настройках безопасности, параметрах AWG 2.0, дополнительных командах управления, технических деталях и ответах на другие вопросы вы можете найти в файле **[ADVANCED.md](ADVANCED.md)**.

Историю изменений смотрите в **[CHANGELOG.md](CHANGELOG.md)**.

---

<a id="faq-main"></a>
## ❓ FAQ (Основные вопросы)

<details>
  <summary><strong>В: Будет ли работать после обновления ядра?</strong></summary>
  **О:** Да, DKMS должен автоматически пересобрать модуль. Проверьте `dkms status`.
</details>

<details>
  <summary><strong>В: Как полностью удалить AmneziaWG?</strong></summary>
  **О:** Скачайте скрипт установки (если его нет) и запустите: `sudo bash ./install_amneziawg.sh --uninstall`.
</details>

<details>
  <summary><strong>В: Клиенты не подключаются, что делать?</strong></summary>
  **О:** 1. Проверьте статус: `sudo bash /root/awg/manage_amneziawg.sh check`. 2. Проверьте фаервол: `sudo ufw status verbose`. 3. Проверьте конфиг клиента. 4. Проверьте логи: `sudo journalctl -u awg-quick@awg0 -n 50`. 5. Убедитесь, что клиент Amnezia VPN версии **>= 4.8.12.7**.
</details>

<details>
  <summary><strong>В: Можно ли использовать с AWG 1.x клиентами?</strong></summary>
  **О:** Нет. AWG 2.0 несовместим с AWG 1.x. Все клиенты должны поддерживать протокол 2.0. Для AWG 1.x используйте ветку <a href="https://github.com/bivlked/amneziawg-installer/tree/legacy/v4">legacy/v4</a>.
</details>

<details>
  <summary><strong>В: Как обновить скрипты до новой версии?</strong></summary>
  **О:** Скачайте новый скрипт установки и замените скрипты управления на сервере:
  <pre>
  wget -O /root/awg/manage_amneziawg.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/main/manage_amneziawg.sh
  wget -O /root/awg/awg_common.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/main/awg_common.sh
  chmod 700 /root/awg/manage_amneziawg.sh /root/awg/awg_common.sh
  </pre>
  Переустановка сервера не требуется.
</details>

<details>
  <summary><strong>В: Какое максимальное количество клиентов?</strong></summary>
  **О:** Подсеть `/24` по умолчанию позволяет до 253 клиентов (.2 — .254). Для большего числа клиентов используйте подсеть `/16` при установке.
</details>

<details>
  <summary><strong>В: Какой хостинг подходит?</strong></summary>
  **О:** Любой VPS с Ubuntu 24.04, root-доступом и минимум 1 ГБ RAM. Рекомендуем хостинги с незаблокированными IP и неограниченным трафиком. См. <a href="#recomend-hosting">рекомендацию</a>.
</details>

<details>
  <summary><strong>В: Как перенести VPN на другой сервер?</strong></summary>
  **О:** 1. Создайте бэкап: <code>sudo bash /root/awg/manage_amneziawg.sh backup</code>. 2. Скопируйте бэкап на новый сервер. 3. Установите AmneziaWG на новом сервере. 4. Восстановите: <code>sudo bash /root/awg/manage_amneziawg.sh restore /path/to/backup.tar.gz</code>. 5. Перегенерируйте конфиги: <code>sudo bash /root/awg/manage_amneziawg.sh regen</code>.
</details>

> Больше ответов и решений см. в **[ADVANCED.md](ADVANCED.md)**.

---

## 🛠️ Устранение неполадок

1.  **Логи:** `/root/awg/install_amneziawg.log`, `/root/awg/manage_amneziawg.log`
2.  **Статус сервиса:** `sudo systemctl status awg-quick@awg0`
3.  **Статус AmneziaWG:** `sudo awg show`
4.  **Статус UFW:** `sudo ufw status verbose`
5.  **Диагностический отчет:** `sudo bash ./install_amneziawg.sh --diagnostic`
    Подробное описание содержимого отчета см. в [ADVANCED.md](ADVANCED.md#diagnostic-report-adv).

---

<a id="licenziya"></a>
## 📝 Лицензия и Автор

* **Автор скриптов:** @bivlked - [GitHub](https://github.com/bivlked)
* **Лицензия:** MIT License (см. файл `LICENSE` в репозитории)

---

<p align="center">
  <a href="#автоматическая-установка-и-управление-amneziawg-20">↑ К началу</a>
</p>

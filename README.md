<a id="top"></a>
<p align="center">
  <b>RU</b> Русский | <b>EN</b> <a href="README.en.md">English</a>
</p>

<p align="center">
  <img src="logo.jpg" alt="AmneziaWG 2.0 VPN installer for Ubuntu, Debian, Raspberry Pi and ARM64 VPS" width="600">
</p>

<h1 align="center">Install AmneziaWG 2.0 VPN on Ubuntu and Debian VPS</h1>

<p align="center"><em>VPN за одну команду - работает там, где WireGuard блокируют. Любой VPS за $3, без знания Linux.</em></p>
<p align="center"><em>One-command, self-hosted AmneziaWG 2.0 VPN for Ubuntu 24.04 / 25.10 / 26.04 and Debian 12 / 13. Kernel-native DKMS, no Docker, no web panel, runs on any cheap VPS.</em></p>

<p align="center">
  <a href="https://bivlked.github.io/amneziawg-installer/ru/"><img src="https://img.shields.io/badge/Website-bivlked.github.io-3ddc97" alt="Project website"></a>
  <img src="https://img.shields.io/badge/Ubuntu-24.04_|_25.10_|_26.04-orange" alt="Ubuntu 24.04 | 25.10 | 26.04">
  <img src="https://img.shields.io/badge/Debian-12_|_13-A81D33" alt="Debian 12 | 13">
  <img src="https://img.shields.io/badge/Architecture-x86__64_|_ARM64_|_ARMv7-green" alt="x86_64 | ARM64 | ARMv7">
  <img src="https://img.shields.io/badge/AmneziaWG-2.0-blueviolet" alt="AWG 2.0">
  <a href="https://github.com/bivlked/amneziawg-installer/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="License"></a>
  <a href="https://github.com/bivlked/amneziawg-installer/releases"><img src="https://img.shields.io/badge/Installer_Version-5.21.0-blue" alt="Version"></a>
  <a href="https://github.com/bivlked/amneziawg-installer/actions/workflows/test.yml"><img src="https://github.com/bivlked/amneziawg-installer/actions/workflows/test.yml/badge.svg" alt="Tests"></a>
  <a href="https://github.com/bivlked/amneziawg-installer/stargazers"><img src="https://img.shields.io/github/stars/bivlked/amneziawg-installer?style=flat" alt="Stars"></a>
  <img src="https://img.shields.io/github/last-commit/bivlked/amneziawg-installer" alt="Last commit">
  <a href="https://deepwiki.com/bivlked/amneziawg-installer"><img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki"></a>
</p>

<p align="center">
  <b>В ядре, без Docker и панелей - нет накладных расходов</b> &nbsp;|&nbsp; <b>сервер только под VPN, защита из коробки</b> &nbsp;|&nbsp; <b>поставил и забыл</b> &nbsp;|&nbsp; <b>QR-код или vpn:// в один тап</b>
</p>

<a id="quickstart"></a>
## 🚀 Быстрый старт

```bash
wget -O install_amneziawg.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.21.0/install_amneziawg.sh
chmod +x install_amneziawg.sh
sudo bash ./install_amneziawg.sh
```

> Что делает: ставит AmneziaWG 2.0 (модуль ядра через DKMS), настраивает firewall и форвардинг, создаёт первого клиента, печатает QR-код и `vpn://` ссылку для импорта в Amnezia Client. Добавить друга или устройство потом - одна команда `add`.
> 3 команды. 2 перезагрузки по ходу. Около 20 минут до готового VPN. Для чистого Ubuntu/Debian VPS, не роутер и не shared-хостинг. [Подробнее →](#ustanovka)

> 📘 Полный гайд по развёртыванию (EN): [Install AmneziaWG VPN server on Ubuntu/Debian VPS](INSTALL_VPS.md) - выбор VPS, ARM, troubleshooting, удаление.

> 🔐 Целостность: скрипт качается по HTTPS с `raw.githubusercontent.com` (тег закреплён), вспомогательные скрипты (`awg_common`, `manage`) проверяются по закреплённым SHA256-хешам. Отдельные detached-подписи релизов пока не активны (запланированы) - статус и модель угроз в [SECURITY.md](SECURITY.md).

<details>
<summary><strong>Что установщик меняет на сервере (прозрачность)</strong></summary>

Скрипт получает root - вот краткий список того, что он делает с системой:

- **Пакеты**: обновляет систему, ставит зависимости (amneziawg-tools, qrencode и т.д.); вычищает ненужное на VPN-сервере - в т.ч. `unattended-upgrades` (значит, обновления безопасности перестают ставиться автоматически) и `cloud-init`, если он не управляет сетью (полный список в [ADVANCED.md](ADVANCED.md)).
- **Ядро**: подключает PPA Amnezia (GPG-ключ проверяется по полному отпечатку) и собирает модуль AmneziaWG через DKMS.
- **Сеть**: sysctl - форвардинг, сетевые буферы, BBR (отдельными файлами в `/etc/sysctl.d/`); IPv6 на хосте по умолчанию выключается (оставить: `--allow-ipv6`); swap подгоняется под размер RAM.
- **Защита**: UFW - входящие запрещены, SSH с rate-limit, открыт только UDP-порт VPN; Fail2Ban для SSH.
- **Файлы и сервисы**: основные файлы в `/root/awg/` и `/etc/amnezia/amneziawg/` с правами 600/700; сервис `awg-quick@awg0`; крон автоудаления истёкших клиентов.
- **Откат**: `--uninstall` убирает своё - модуль, конфиги, sysctl-файлы, кроны, UFW-правило VPN-порта и UFW-правило маршрутизации `awg0`. UFW отключает и Fail2Ban удаляет только если сам их включал/ставил; если UFW был активен до установки, добавленное правило SSH rate-limit остаётся. Не возвращает: swap и удалённые пакеты.

Пошаговые детали - в [ADVANCED.md](ADVANCED.md), модель угроз - в [SECURITY.md](SECURITY.md).
</details>

<details>
<summary><strong>Неинтерактивная установка (для автоматизации)</strong></summary>

```bash
sudo bash ./install_amneziawg.sh --yes --route-all
```

Все параметры принимаются автоматически. Подробнее: [ADVANCED.md#cli-params-adv](ADVANCED.md#cli-params-adv)
</details>

### 🎯 Выберите свой случай

| Ваша ситуация | Что добавить |
|---|---|
| Обычный дешёвый VPS, просто нужен VPN | Ничего - команда выше уже всё делает |
| Мобильный интернет, DPI режет (ТСПУ, Иран, школа или корпоратив) | При установке добавьте `--mobile` - пресет обфускации + порт 443/udp разом ([проверенные операторы](#operatory)) |
| ARM: Raspberry Pi, Oracle Ampere, Hetzner CAX | Та же команда - готовые ARM-модули ядра выберутся автоматически ([детали](INSTALL_VPS.md)) |
| Доступ другу или гостю на время | После установки: `manage_amneziawg.sh add guest --expires=7d` |

---

<p align="center">
  <a href="#zachem">Зачем это нужно</a> •
  <a href="#sravnenie">AWG vs WG</a> •
  <a href="#cli-vs-panel">CLI vs панели</a> •
  <a href="#similar-tools">Похожие инструменты</a> •
  <a href="#quickstart">Быстрый старт</a> •
  <a href="#vozmozhnosti">Что умеет</a> •
  <a href="#operatory">Операторы</a> •
  <a href="#trebovaniya">Требования</a> •
  <a href="#recomend-hosting">Хостинг</a> •
  <a href="#ustanovka">Установка</a> •
  <a href="#posle-ustanovki">После установки</a> •
  <a href="#upravlenie">Управление</a> •
  <a href="#dopolnitelno">Дополнительно</a> •
  <a href="#faq-main">FAQ</a> •
  <a href="#nepoladki">Устранение неполадок</a> •
  <a href="#ekosistema">Экосистема</a> •
  <a href="#licenziya">Лицензия</a>
</p>

<a id="zachem"></a>
## 💡 Зачем это нужно

[AmneziaWG](https://github.com/amnezia-vpn) - форк WireGuard с обфускацией трафика. Обфускация делает трафик трудноотличимым от случайного шума для систем DPI, поэтому там, где обычный WireGuard детектируют и блокируют, AmneziaWG обычно продолжает работать.

Этот набор скриптов превращает чистый VPS в готовый VPN-сервер. Не нужны знания Linux - скрипт сам настроит firewall, оптимизирует систему, создаст конфиги и QR-коды для клиентов.

Сервер настраивается под одну задачу - VPN: лишние пакеты убираются, ядро, сеть и swap тюнингуются под железо, включаются firewall и базовая защита. AmneziaWG работает в ядре, поэтому накладных расходов почти нет - быстро и экономно. Поставил один раз для дома или семьи и забыл: добавить друга или новое устройство через месяц - минута, конфиг и QR готовятся одной командой.

Работает на Ubuntu 24.04/25.10/26.04 и Debian 12/13. Хватит любого дешёвого VPS с 1 ГБ RAM.

---

<a id="sravnenie"></a>
## ⚖️ AmneziaWG vs WireGuard

| | WireGuard | AmneziaWG 2.0 |
|---|---|---|
| **Обнаружение DPI** | Детектируется по фиксированным размерам пакетов и magic bytes | Трудно зафингерпринтить - случайные заголовки, padding, имитация протоколов |
| **Блокируется в** | Китай, Россия, Иран, ОАЭ, Туркменистан | Не известно о блокировках (по состоянию на апрель 2026) |
| **Настройка сервера** | Вручную: ключи, iptables, sysctl, systemd | Одна команда, 20 минут, полностью автоматически |
| **Безопасность** | Сами: UFW, Fail2Ban, sysctl | Автоматически: firewall + защита от брутфорса + тюнинг ядра |
| **Управление клиентами** | Ручное редактирование конфигов, рестарт | `add`/`remove`/`list`/`stats` с hot-reload |
| **Временный доступ** | Нет | `--expires=7d` с автоматическим удалением |
| **Требования к серверу** | - | Те же - любой VPS за $3-5/мес, 1 ГБ RAM |
| **Потеря скорости** | Базовая | Минимальная (<2% в типичных тестах) |

> Если WireGuard у вас работает и не блокируется - используйте его. Если блокируется или режется - AmneziaWG 2.0 является прямой заменой.

---

<a id="cli-vs-panel"></a>
## ⚙️ CLI-инсталлер vs веб-панели

> **Задача - поднять VPN на дешёвом VPS за 20 минут.** Скрипт не тянет за собой Docker, веб-сервер или базу данных. После установки на сервере работает только AWG и firewall - минимум нагрузки, максимум ресурсов для VPN.

| | Этот проект (CLI) | Веб-панели на Docker |
|---|---|---|
| **Модуль AWG** | Kernel module - работает на уровне ядра | Userspace в контейнере |
| **Требования к серверу** | Любой VPS от 512 МБ RAM | Нужны PHP/Python, БД, веб-сервер, Docker |
| **Поверхность атаки** | SSH + UDP-порт VPN | + HTTP-панель, база данных, Docker |
| **Установка** | Одна команда на сервере, 20 минут | docker-compose + передача SSH-доступа панели |
| **После перезагрузки** | Продолжит установку с того же шага | Зависит от состояния контейнеров и БД |
| **Веб-интерфейс** | ❌ Нет, только SSH (управление через скрипт `manage`) | ✅ GUI, управление через браузер |
| **Несколько протоколов** | Только AmneziaWG | WireGuard, OpenVPN, VLESS и другие |

> Нужен VPN без GUI на выделенном сервере - этот проект. Нужна веб-панель с несколькими протоколами - ищите Docker-решения.

---

<a id="similar-tools"></a>
## 🔧 Сравнение с похожими инструментами

Есть ещё несколько способов поднять AmneziaWG. Каждый выбирает свой компромисс:

| Инструмент | Способ | Кому подходит |
|---|---|---|
| **Этот установщик** | SSH + одна bash-команда | Headless VPS, single-purpose сервер, без Docker и панели, ARM-prebuilt'ы |
| **[wiresock/amneziawg-install](https://github.com/wiresock/amneziawg-install)** | SSH + bash, опц. нативная веб-панель и обфускация-прокси (Rust) | Нужна веб-панель без Docker или маскировка трафика отдельным сервисом |
| **[wg-easy](https://github.com/wg-easy/wg-easy)** | Docker + веб-интерфейс | Домашние боксы, на которых уже крутится Docker; нужна панель для клиентов |
| **[spcfox/amnezia-wg-easy](https://github.com/spcfox/amnezia-wg-easy)** | Docker-форк wg-easy | Те, кто уже на wg-easy и хочет именно AmneziaWG вместо обычного WireGuard |
| **[Amnezia VPN](https://amnezia.org/)** | Десктоп/моб GUI, разворачивает сервер в Docker по SSH | Установка кликами без терминала; нужен графический клиент |

**Быстрый выбор:**

* Часто заводишь и меняешь клиентов, удобнее мышкой в браузере - веб-панель: **wiresock** (нативная, без Docker) или **wg-easy** (Docker). Учти: панель - это лишний постоянно работающий сервис, открытый порт и расход ресурсов сервера; для режима «поставил и забыл» это ненужная нагрузка.
* Дешёвый или слабый VPS, ARM (Raspberry Pi, Oracle Ampere) - **этот установщик** с готовыми prebuilt'ами, без ожидания сборки модуля.
* Импорт в телефон одним тапом (QR или `vpn://`), клиенты по сроку (`--expires`), пресеты под мобильных операторов - **этот установщик**.
* Установка мышкой без терминала - десктоп-клиент **Amnezia VPN**.

**Когда этот проект - не лучший выбор:**

* Часто заводишь и меняешь клиентов и хочется браузерную панель - возьми **wiresock** или **wg-easy**. Здесь панели нет осознанно: если клиенты меняются изредка, постоянно работающая панель только ест ресурсы сервера, а управление и так делается из CLI (`manage` add/remove/list) по SSH.
* Нужна устойчивость к активному зондированию (active probing) - маскировка трафика под сторонний протокол (например QUIC или DNS): у **wiresock** для этого есть отдельный обфускация-прокси (серверную маскировку получает любой стандартный клиент, полная двунаправленная - в связке с их коммерческим клиентом WireSock Secure Connect). Здесь обфускация делается в самом протоколе - параметры I1-I5/CPS AmneziaWG 2.0 - и ориентирована на типовой мобильный DPI, без отдельного прокси-демона и платного клиента.
* Нужен графический клиент или установка мышкой без терминала - десктоп-клиент **Amnezia VPN**.

### Чем отличается от официального приложения Amnezia?

Официальное приложение Amnezia - официальный графический клиент: ставишь приложение, указываешь сервер, и оно разворачивает серверную часть в Docker по SSH. Удобно, когда нужен только GUI. Этот установщик создан под другую задачу - выжать из одного выделенного VPS максимум как из VPN-сервера. Отсюда и отличия:

* **Без Docker и накладных расходов на него.** AmneziaWG ставится модулем ядра, а не в контейнере. Нет постоянного Docker-демона - меньше расход RAM и CPU. На дешёвом VPS это критично, на сервере помощнее тоже не лишнее.
* **Сервер оптимизируется под железо.** Скрипт смотрит на RAM и сетевую карту и настраивает sysctl-буферы, размер swap, офлоады NIC, включает BBR - вытягивает из тарифа максимум. Официальное приложение разворачивает контейнеры и сам сервер не оптимизирует и не настраивает.
* **Меньше поверхность атаки.** Лишние пакеты и службы вырезаются, на сервере остаётся одна задача - VPN. Сверху UFW deny-all, Fail2Ban, строгие права на файлы и sysctl-хардненинг.
* **Тонкая настройка обфускации.** Пресет для мобильных сетей (`--preset=mobile`), прямой доступ к параметрам AmneziaWG 2.0 и полевые данные по операторам и DPI - можно подстроить под конкретную сеть или оператора.
* **Headless и автоматизация.** Одна SSH-команда, все параметры флагами, управление клиентами из CLI, гости по сроку (`--expires`), импорт по QR или `vpn://`, готовые сборки под ARM.

Протокол и стойкость к DPI при этом одинаковые - под капотом тот же AmneziaWG 2.0. Код открыт под MIT, это читаемый bash, его можно просмотреть перед запуском, на нём 1100+ автотестов. Ставится тот же upstream AmneziaWG - это автоматизация и тюнинг сервера, а не форк протокола.

Подробное сравнение: [amneziawg-installer и официальное приложение Amnezia](https://bivlked.github.io/amneziawg-installer/ru/compare/).

---

<a id="vozmozhnosti"></a>
## ✨ Что умеет

* **Обход блокировок** - AmneziaWG 2.0 с обфускацией трафика. DPI не детектирует подключение
* **Одна команда - готовый VPN** - от чистого VPS до работающего сервера с клиентскими конфигами и QR-кодами
* **Безопасность из коробки** - UFW, Fail2Ban, sysctl hardening, строгие права доступа (600/700)
* **Удобное управление** - добавление/удаление клиентов, временные клиенты с авто-удалением, статистика, бэкапы
* **Широкая поддержка ОС** - Ubuntu 24.04/25.10/26.04 и Debian 12/13
* **x86_64 и ARM** - облачные VPS, Raspberry Pi 3/4/5, ARM64-серверы (AWS Graviton, Oracle Ampere, Hetzner)
* **Оптимизация для мобильных сетей** - `--preset=mobile` для Tele2, Yota, Мегафон и других операторов с DPI-блокировками. Тонкая настройка через `--jc`, `--jmin`, `--jmax` ([подробнее](ADVANCED.md#presets-adv))
* **Опциональный dual-stack IPv6** - флаг `--allow-ipv6-tunnel` добавляет IPv6 внутри туннеля рядом с IPv4 (по умолчанию выключено, [подробнее](ADVANCED.md#ipv6-tunnel-adv))

<details>
<summary><strong>Все возможности</strong></summary>

* Нативная генерация ключей и конфигов через `awg` - без Python и внешних зависимостей
* Hardware-aware оптимизация: swap, NIC offloads, сетевые буферы на основе характеристик сервера
* DKMS - автоматическая пересборка модуля ядра при обновлении
* `vpn://` URI для импорта в Amnezia Client одним тапом (`.vpnuri` файлы)
* Статистика трафика по клиентам (`stats`, `stats --json`)
* Временные клиенты с авто-удалением (`--expires=1h`, `7d`, `4w` и др.)
* Диагностический отчёт (`--diagnostic`) и полная деинсталляция (`--uninstall`)
* Логирование всех действий в `/root/awg/`
* Возобновление установки после перезагрузки - скрипт продолжит с нужного шага
* Выбор порта, подсети, режима IPv6, маршрутизации и изоляции клиентов (`--isolation=on|off`). Поддержка `--endpoint` для серверов за NAT
</details>

---

<a id="operatory"></a>
## 📡 С какими операторами проверено

Установщик настраивает обфускацию AmneziaWG 2.0 под мобильные сети с DPI: `--mobile` включает мобильный пресет и порт 443/udp одним флагом. Если VPN нестабилен через мобильный интернет - переустановите с `--mobile`. Ниже - рабочие конфигурации по отчётам пользователей из issues и discussions (не гарантия: блокировки и параметры операторов меняются со временем):

- **Yota** - Москва, `--preset=mobile`
- **Tele2** - Москва (`--preset=mobile`); Красноярск (`--preset=mobile`; в майскую волну 2026 заработал `I1=<r 48>`)
- **Таттелеком / Летай** - Татарстан, `--preset=mobile`
- **Мегафон** - регионы, `--preset=mobile` + удалить параметр `I1`
- **Билайн** - дефолтный preset, флаги не нужны
- **Домашний/проводной интернет** - дефолт, как правило, «из коробки»

Вашего оператора нет в списке? Попробуйте `--preset=mobile`. Не помогло - заведите тред в [Discussions](https://github.com/bivlked/amneziawg-installer/discussions) или [Issues](https://github.com/bivlked/amneziawg-installer/issues), добавлю в список.

> Полная таблица операторских параметров (Jc, Jmin, Jmax, I1) - в [ADVANCED.md → FAQ «через мобильную сеть»](ADVANCED.md#faq-advanced-adv). Точечная настройка через `--jc`/`--jmin`/`--jmax` - в [ADVANCED.md → Presets](ADVANCED.md#presets-adv).

---

<a id="trebovaniya"></a>
## 🖥️ Требования

* **ОС:** **Чистая** установка **Ubuntu Server 24.04 LTS** / **Ubuntu 25.10** / **Ubuntu 26.04** / **Debian 12** / **Debian 13** Minimal
* **Доступ:** Права `root` (через `sudo`)
* **Интернет:** Стабильное подключение
* **Ресурсы:** 512 МБ ОЗУ минимум, рекомендуется 1 ГБ (комфортно 2+ ГБ); минимум ~2 ГБ диска (рекомендуется 3+ ГБ)
* **SSH:** Доступ по SSH

**Совместимость ОС:**

| ОС | Статус | Примечание |
|----|--------|------------|
| Ubuntu 24.04 LTS | ✅ Полная поддержка | Рекомендуется |
| Ubuntu 25.10 | ✅ Поддерживается | PPA `noble` fallback применяется автоматически с v5.13.0 |
| Ubuntu 26.04 | ✅ Поддерживается | PPA `noble` fallback применяется автоматически с v5.13.0 |
| Debian 12 (bookworm) | ✅ Поддержка | Протестировано. PPA через маппинг codename на focal |
| Debian 13 (trixie) | ✅ Поддержка | Протестировано. PPA через маппинг codename на noble, DEB822 |

**Поддержка архитектур (v5.10.0+):**

| Архитектура | Статус | Платформы |
|---|---|---|
| x86_64 (amd64) | ✅ Полная поддержка | Все облачные VPS |
| ARM64 (aarch64) | ✅ Поддержка | Raspberry Pi 3/4/5, AWS Graviton, Oracle Ampere, Hetzner |
| ARMv7 (armhf) | ✅ Поддержка | Raspberry Pi 3/4 (32-bit) |

> На ARM установщик загружает готовые модули ядра при наличии, и автоматически переключается на DKMS-сборку если нужно.

> ⚠️ **Нестандартный порт SSH:** Установщик обычно определяет SSH-порт автоматически. Если SSH на нестандартном порту или автодетект недоступен, запускайте с `--ssh-port=ВАШ_ПОРТ` (несколько портов - списком через запятую). Как дополнительная консервативная страховка можно заранее выполнить `sudo ufw allow ВАШ_ПОРТ/tcp` **до** запуска установки.

**Клиенты:**
* **Все платформы:** [Amnezia VPN](https://github.com/amnezia-vpn/amnezia-client/releases) **>= 4.8.12.7** - полнофункциональный VPN-клиент с AWG 2.0. Импорт через `vpn://` URI
* **Windows:** [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-windows-client/releases) **>= 2.0.0** - легковесный tunnel manager с AWG 2.0. Импорт через `.conf` файлы

> [Полная таблица совместимости клиентов →](ADVANCED.md#client-compat-adv)

---

<a id="recomend-hosting"></a>
## 🚀 Рекомендация хостинга

Для стабильной работы VPN-сервера с высокой пропускной способностью важен надежный хостинг с хорошим каналом.

**На что смотреть при выборе VPS под VPN:**
- IP-адреса, не помеченные как датацентровые - меньше риск блокировок по диапазону.
- Большой или неограниченный трафик и канал от 1 Гбит/с.
- Поддержка нужной ОС (Ubuntu 24.04+ / Debian 12+) и root-доступ.

Опробовал и рекомендую [**FreakHosting**](https://freakhosting.com/clientarea/aff.php?aff=392). В частности, их линейка **BUDGET VPS** предлагает отличное соотношение цены и качества.

Их IP-адреса не идентифицируются, как адреса датацентров и не попадают под блокировки по признаку «IP принадлежит хостинг-провайдеру» (в отличие, например, от Azure и некоторых крупных облаков).

* **Рекомендуемый тариф:** **BVPS-2**
* **Характеристики:** 2 vCPU, 2 GB RAM, 40 GB NVMe SSD.
* **Ключевое преимущество:** порт **10 Gbps** с **неограниченным трафиком**. Идеально для VPN!
* **Цена:** Всего **€25 в год** (около 2200 руб.; на момент проверки, цена может меняться).

Этой конфигурации более чем достаточно для комфортной работы AmneziaWG с большим количеством подключений и высоким трафиком.

---

<a id="ustanovka"></a>
## 🔧 Установка (Рекомендуемый способ)

Установка AmneziaWG на Ubuntu или Debian сводится к трём командам: скачать скрипт, запустить с `sudo` и ответить на несколько вопросов. Этот метод гарантирует корректную работу интерактивных запросов и цветного вывода в вашем терминале.

1.  **Подключитесь** к **чистому** серверу (Ubuntu 24.04 / Ubuntu 25.10 / Ubuntu 26.04 / Debian 12 / Debian 13) по SSH.
    > **Совет:** После создания сервера подождите 5-10 минут, чтобы завершились все фоновые процессы инициализации системы, прежде чем запускать установку.

2.  **Скачайте скрипт:**
    ```bash
    wget -O install_amneziawg.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.21.0/install_amneziawg.sh
    # или: curl -fLo install_amneziawg.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.21.0/install_amneziawg.sh
    ```
    > На минимальном Debian curl может отсутствовать (wget обычно есть) - используйте `wget`. Сам curl установщик доставит на шаге 1.
3.  **Сделайте его исполняемым:**
    ```bash
    chmod +x install_amneziawg.sh
    ```
4.  **Запустите с `sudo`:**
    ```bash
    sudo bash ./install_amneziawg.sh
    ```
    *(Вы также можете передать параметры командной строки, см. `sudo bash ./install_amneziawg.sh --help` или [ADVANCED.md#install-cli-adv](ADVANCED.md#install-cli-adv))*

    > **English version:** Для вывода на английском используйте `install_amneziawg_en.sh`:
    > ```bash
    > wget -O install_amneziawg_en.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.21.0/install_amneziawg_en.sh
    > sudo bash ./install_amneziawg_en.sh
    > ```
    > Английская версия функционально идентична; только сообщения и логи на английском.
    > После перезагрузки продолжайте тем же файлом: `sudo bash ./install_amneziawg_en.sh`

5.  **Начальная настройка:** Скрипт интерактивно запросит:
    * **UDP порт:** Порт для подключения клиентов (1-65535). По умолчанию: `39743`.
    * **Подсеть туннеля:** Внутренняя сеть для VPN. По умолчанию: `10.9.9.1/24`.
    * **Отключение IPv6:** Рекомендуется отключить (`Y`) для избежания утечек трафика.
    * **Режим маршрутизации:** Определяет, какой трафик пойдет через VPN. По умолчанию `2` (Список Amnezia+DNS) - рекомендуется для лучшей совместимости и обхода блокировок.
    * **Изоляция клиентов:** Блокировать ли трафик между клиентами внутри VPN. По умолчанию включена (`Y`) - клиенты не видят друг друга; неинтерактивно: `--isolation=on|off`.

    * **Имя сервера:** Под этим именем сервер появится в приложении Amnezia при импорте `vpn://`. По умолчанию `AWG Server`; неинтерактивно: `--server-name=ИМЯ`.

    Параметры AWG 2.0 (Jc, S1-S4, H1-H4, I1) генерируются **автоматически** - никаких действий не требуется.

6.  **Перезагрузки:** Потребуется **ДВЕ** перезагрузки. Скрипт запросит подтверждение `[y/N]`. Введите `y` и нажмите Enter.

7.  **Продолжение:** После каждой перезагрузки **снова запустите скрипт** той же командой:
    ```bash
    sudo bash ./install_amneziawg.sh
    ```
    Скрипт автоматически продолжит с нужного шага **без повторных запросов**.

8.  **Завершение:** После второй перезагрузки и третьего запуска скрипта вы увидите сообщение:
    `Установка и настройка AmneziaWG 2.0 УСПЕШНО ЗАВЕРШЕНА!`

---

<a id="posle-ustanovki"></a>
## 📦 После установки

**Где найти файлы клиентов:**

| Файл | Путь | Назначение |
|------|------|------------|
| `.conf` | `/root/awg/имя.conf` | Конфигурация для импорта в клиент |
| `.png` | `/root/awg/имя.png` | QR-код для мобильных устройств |
| `.vpnuri` | `/root/awg/имя.vpnuri` | `vpn://` URI для Amnezia Client |

**Скачать конфиг на компьютер:**

```bash
scp root@IP_СЕРВЕРА:/root/awg/my_phone.conf .
```

<details>
<summary><strong>Импорт в Amnezia VPN (телефон) через vpn:// URI</strong></summary>

1. На сервере выполните: `cat /root/awg/my_phone.vpnuri`
2. Скопируйте текст и отправьте себе (Telegram, почта и т.д.)
3. На телефоне: Amnezia VPN → «Добавить VPN» → «Вставить из буфера»
</details>

<details>
<summary><strong>Импорт через QR-код</strong></summary>

1. Скачайте QR-код: `scp root@IP_СЕРВЕРА:/root/awg/my_phone.png .`
2. Откройте файл на экране компьютера
3. На телефоне: Amnezia VPN → «Добавить VPN» → «Сканировать QR-код»
</details>

<details>
<summary><strong>Импорт в AmneziaWG for Windows</strong></summary>

1. Скачайте `.conf` файл на компьютер через `scp` или `sftp`
2. AmneziaWG → Import tunnel(s) from file → выберите `.conf` файл
</details>

**Другие файлы на сервере:**

* Конфигурация сервера: `/etc/amnezia/amneziawg/awg0.conf`
* Настройки скрипта: `/root/awg/awgsetup_cfg.init`
* Скрипт управления: `/root/awg/manage_amneziawg.sh`
* Общие функции: `/root/awg/awg_common.sh`
* Данные истечения клиентов: `/root/awg/expiry/`
* Логи: `/root/awg/*.log`

---

<a id="upravlenie"></a>
## 👥 Управление клиентами (`manage_amneziawg.sh`)

Скрипт `manage_amneziawg.sh` для управления пользователями скачивается автоматически.

**Использование:**

```bash
sudo bash /root/awg/manage_amneziawg.sh <команда> [аргументы]
```

Полный список - `... help` или [ADVANCED.md#manage-commands-adv](ADVANCED.md#manage-commands-adv).

**Повседневные команды:**

| Команда   | Аргументы              | Описание                     | Перезапуск? |
| :-------- | :--------------------- | :--------------------------- | :-----------: |
| `add`     | `<имя> [имя2 ...] [--expires=ВРЕМЯ]` | Добавить клиента(ов) (опц. с истечением) | Нет (авто) |
| `remove`  | `<имя> [имя2 ...]`     | Удалить клиента(ов)          |  Нет (авто) |
| `list`    | `[-v] [--json]`        | Список клиентов (`-v` детали, `--json` машиночитаемый с `client_ipv6`) |       Нет     |
| `show`    |                        | Статус `awg show`            |       Нет     |
| `stats`   | `[--json]`             | Статистика трафика по клиентам |       Нет     |

**Обслуживание и восстановление:**

| Команда   | Аргументы              | Описание                     | Перезапуск? |
| :-------- | :--------------------- | :--------------------------- | :-----------: |
| `regen`   | `[имя ...] [--reset-routes]` | Переген. файлы (всех/указанных) |       Нет     |
| `modify`  | `<имя> <пар> <зн>`     | Изменить параметр клиента    |       Нет     |
| `backup`  |                        | Создать резервную копию      |       Нет     |
| `restore` | `[файл]`               | Восстановить из резервной копии |    Нет     |
| `check`   |                        | Проверка состояния сервера     |       Нет     |
| `diagnose`| `[--carrier=ИМЯ]`      | Диагностика (опц. под оператора) |     Нет     |
| `repair-module` |                  | Пересобрать модуль ядра (DKMS)   |     Да      |
| `restart` |                        | Перезапуск сервиса AmneziaWG   |       -       |

> **💡 Примечание:** Команды `add` и `remove` автоматически применяют изменения через `awg syncconf` - перезапуск сервиса не требуется.

> **🤖 Для скриптов и ботов:** с v5.21.0 почти все команды управления (от `add` до `repair-module`) понимают `--json` и отвечают одним JSON-объектом, даже если что-то пошло не так - вывод можно спокойно разбирать из своего скрипта или бота. `list --json` и `stats --json`, как и раньше, отдают простые массивы. Формат и строгий режим подтверждений `AWG_STRICT_CONFIRM=1` расписаны в [ADVANCED.md → JSON-интерфейс](ADVANCED.md#json-api-adv), а готовый Telegram-бот на этом интерфейсе уже есть - [awgram](#ekosistema).

### 📌 Краткая справка

```bash
# Установка (русский)
wget -O install_amneziawg.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.21.0/install_amneziawg.sh
sudo bash ./install_amneziawg.sh          # Запуск (+ 2 перезагрузки)

# Установка (English)
wget -O install_amneziawg_en.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.21.0/install_amneziawg_en.sh
sudo bash ./install_amneziawg_en.sh       # Запуск (+ 2 перезагрузки)

# Управление клиентами
sudo bash /root/awg/manage_amneziawg.sh add my_phone       # Добавить
sudo bash /root/awg/manage_amneziawg.sh add my_iphone --psk  # +PresharedKey (Shadowrocket iOS/macOS)
sudo bash /root/awg/manage_amneziawg.sh remove my_phone    # Удалить
sudo bash /root/awg/manage_amneziawg.sh list                # Список
sudo bash /root/awg/manage_amneziawg.sh list --json         # Список в JSON (для скриптов)
sudo bash /root/awg/manage_amneziawg.sh regen               # Перегенерация

# Временный клиент (7 дней)
sudo bash /root/awg/manage_amneziawg.sh add guest --expires=7d

# Статистика трафика
sudo bash /root/awg/manage_amneziawg.sh stats
sudo bash /root/awg/manage_amneziawg.sh stats --json

# Обслуживание
sudo bash /root/awg/manage_amneziawg.sh check               # Диагностика
sudo bash /root/awg/manage_amneziawg.sh backup               # Бэкап
sudo bash /root/awg/manage_amneziawg.sh restart              # Перезапуск
```

---

<a id="dopolnitelno"></a>
## ℹ️ Дополнительная информация

Более подробную информацию о деталях конфигурации, настройках безопасности, параметрах AWG 2.0, дополнительных командах управления, технических деталях и ответах на другие вопросы вы можете найти в файле **[ADVANCED.md](ADVANCED.md)**.

Историю изменений смотрите в **[CHANGELOG.md](CHANGELOG.md)**.

Планы развития и приоритеты - в **[docs/ROADMAP.md](docs/ROADMAP.md)**.

Каскад из двух серверов с раздельным выходом российского и зарубежного трафика (split-tunnel) - в **[CASCADE.md](CASCADE.md)**.

---

<a id="faq-main"></a>
## ❓ FAQ (Основные вопросы)

> **В разделе:** установка и обновление, подключение клиентов, мобильные сети, выбор хостинга и перенос, безопасность и параметры. Разверните нужный вопрос ниже.

<details>
  <summary><strong>В: Будет ли работать после обновления ядра?</strong></summary>
  <b>О:</b> Да, DKMS должен автоматически пересобрать модуль. Проверьте <code>dkms status</code>.
</details>

<details>
  <summary><strong>В: Как полностью удалить AmneziaWG?</strong></summary>
  <b>О:</b> Скачайте скрипт установки (если его нет) и запустите: <code>sudo bash ./install_amneziawg.sh --uninstall</code>.
</details>

<details>
  <summary><strong>В: Клиенты не подключаются, что делать?</strong></summary>
  <b>О:</b> 1. Проверьте статус: <code>sudo bash /root/awg/manage_amneziawg.sh check</code>. 2. Проверьте фаервол: <code>sudo ufw status verbose</code>. 3. Проверьте конфиг клиента. 4. Проверьте логи: <code>sudo journalctl -u awg-quick@awg0 -n 50</code>. 5. Убедитесь, что клиент поддерживает AWG 2.0: Amnezia VPN <b>>= 4.8.12.7</b> или AmneziaWG <b>>= 2.0.0</b>.
</details>

<details>
  <summary><strong>В: Handshake проходит, но трафик не идёт - что не так?</strong></summary>
  <b>О:</b> Частая причина - split-tunneling AllowedIPs gotcha при ручной правке. Если хочешь пинговать/SSH'иться к серверу по его внутреннему IP (<code>10.9.9.1</code> в дефолтной подсети), добавь в <code>AllowedIPs</code> клиента <b>подсеть туннеля</b> (по умолчанию <code>10.9.9.0/24</code>, или твою кастомную, если менял <code>--subnet</code>). Иначе клиент не маршрутизирует трафик к серверу даже изнутри тоннеля. Режим <code>--route-all</code> (полный туннель <code>0.0.0.0/0</code>) покрывает подсеть автоматически; режим <code>--route-amnezia</code> (по умолчанию, Amnezia List) и <code>--route-custom=</code> - нет, добавляй вручную. Подробнее - в <a href="ADVANCED.md#allowedips-adv">ADVANCED.md → AllowedIPs</a>.
  <br><br>
  Отдельно от режима маршрутизации: по умолчанию клиенты изолированы друг от друга на сервере (правило <code>FORWARD awg0→awg0 DROP</code>), даже если оба в одном режиме. Чтобы устройства видели друг друга внутри VPN, ставь <code>--isolation=off</code> при установке - сервер снимает блокировку, а подсеть туннеля сама добавляется в <code>AllowedIPs</code> клиентов. Подробнее - в <a href="ADVANCED.md#client-isolation-adv">ADVANCED.md → Изоляция клиентов</a>.
</details>

<details>
  <summary><strong>В: Можно сделать так, чтобы российский трафик шёл напрямую, а остальное - через заграницу?</strong></summary>
  <b>О:</b> Да, через каскад из двух серверов: клиент подключается к серверу-входу (лучше в РФ), российский трафик уходит в интернет напрямую с него, остальное - через второй сервер за границей. Деление на стороне сервера, на клиенте ничего особого настраивать не нужно. Пошаговая инструкция - в <a href="CASCADE.md">CASCADE.md</a>.
</details>

<details>
  <summary><strong>В: Можно ли использовать с AWG 1.x клиентами?</strong></summary>
  <b>О:</b> Нет. AWG 2.0 несовместим с AWG 1.x. Все клиенты должны поддерживать протокол 2.0. Для AWG 1.x используйте ветку <a href="https://github.com/bivlked/amneziawg-installer/tree/legacy/v4">legacy/v4</a>.
</details>

<details>
  <summary><strong>В: Ошибка импорта конфига «Неверный ключ: s3» - что делать?</strong></summary>
  <b>О:</b> Вы используете устаревшую версию <code>amneziawg-windows-client</code> (< 2.0.0). Обновите до <a href="https://github.com/amnezia-vpn/amneziawg-windows-client/releases"><b>версии 2.0.0+</b></a>, которая поддерживает AWG 2.0. Альтернатива - <a href="https://github.com/amnezia-vpn/amnezia-client/releases"><b>Amnezia VPN</b></a> >= 4.8.12.7.
</details>

<details>
  <summary><strong>В: Как обновить скрипты до новой версии?</strong></summary>
  <b>О:</b> Скачайте новый скрипт установки и замените скрипты управления на сервере:
  <pre>
  # Русская версия:
  wget -O /root/awg/manage_amneziawg.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.21.0/manage_amneziawg.sh
  wget -O /root/awg/awg_common.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.21.0/awg_common.sh
  chmod 700 /root/awg/manage_amneziawg.sh /root/awg/awg_common.sh

  # Английская версия:
  wget -O /root/awg/manage_amneziawg.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.21.0/manage_amneziawg_en.sh
  wget -O /root/awg/awg_common.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.21.0/awg_common_en.sh
  chmod 700 /root/awg/manage_amneziawg.sh /root/awg/awg_common.sh
  </pre>
  Переустановка сервера не требуется.
  <br><br>
  С v5.21.0 пара скриптов защищена от рассинхрона: обновили manage, а awg_common забыли (или наоборот), и версии разошлись - скрипт остановится и покажет, какими командами докачать вторую половину, вместо странных ошибок посреди работы.
</details>

<details>
  <summary><strong>В: Какое максимальное количество клиентов?</strong></summary>
  <b>О:</b> Подсеть <code>/24</code> по умолчанию позволяет до 253 клиентов (.2 - .254), что достаточно для большинства сценариев. Нужно больше - укажите более широкую маску через <code>--subnet</code> (например, <code>/16</code>).
</details>

<details>
  <summary><strong>В: Какой хостинг подходит?</strong></summary>
  <b>О:</b> Любой VPS с Ubuntu 24.04 LTS / Ubuntu 25.10 / Ubuntu 26.04 / Debian 12 / Debian 13, root-доступом и от 512 МБ RAM (рекомендуется 1 ГБ). Беру хостинги с незаблокированными IP и неограниченным трафиком. См. <a href="#recomend-hosting">рекомендацию</a> ниже.
</details>

<details>
  <summary><strong>В: Как перенести VPN на другой сервер?</strong></summary>
  <b>О:</b> 1. Создайте бэкап: <code>sudo bash /root/awg/manage_amneziawg.sh backup</code>. 2. Скопируйте архив из <code>/root/awg/backups/</code> на новый сервер. 3. Установите AmneziaWG на новом сервере. 4. Восстановите: <code>sudo bash /root/awg/manage_amneziawg.sh restore</code> (интерактивный выбор из списка, или укажите полный путь к архиву). 5. Перегенерируйте конфиги с новым IP: <code>sudo bash /root/awg/manage_amneziawg.sh regen</code>.
</details>

<details>
  <summary><strong>В: Как создать временного клиента?</strong></summary>
  <b>О:</b> <code>sudo bash /root/awg/manage_amneziawg.sh add guest --expires=7d</code>. Форматы: <code>1h</code>, <code>12h</code>, <code>1d</code>, <code>7d</code>, <code>30d</code>, <code>4w</code>. Cron проверяет каждые 5 минут и автоматически удаляет истёкших клиентов.
</details>

<details>
  <summary><strong>В: Что такое файлы .vpnuri?</strong></summary>
  <b>О:</b> Файлы <code>.vpnuri</code> содержат <code>vpn://</code> URI для импорта конфигурации в Amnezia Client одним тапом. Скопируйте содержимое файла → откройте Amnezia Client → «Добавить VPN» → «Вставить из буфера».
</details>

<details>
  <summary><strong>В: Не подключается Shadowrocket на iOS/macOS - нужен PresharedKey</strong></summary>
  <b>О:</b> С v5.11.1 добавлен флаг <code>--psk</code> для команды <code>add</code>: <code>sudo bash /root/awg/manage_amneziawg.sh add my_iphone --psk</code>. В файле клиента появится строка <code>PresharedKey = ...</code> совпадающая с серверным <code>[Peer]</code>. Для уже созданных клиентов: пересоздать с флагом (<code>remove</code> + <code>add --psk</code>) или вручную - сгенерировать ключ <em>один раз</em> (<code>PSK=$(awg genpsk)</code>) и вставить <em>одно и то же значение</em> в обе стороны (серверный <code>[Peer]</code> клиента и клиентский <code>[Peer]</code> сервера); если значения различаются - handshake не пройдёт. <code>regen</code> сохраняет существующий PSK через rotation. Подробнее - в <a href="ADVANCED.md#manage-cli-adv">ADVANCED.md</a>.
</details>

<details>
  <summary><strong>В: iPhone подключается, но через ~10 секунд трафик пропадает</strong></summary>
  <b>О:</b> Исправлено в v5.16.1 (Issue #42, спасибо @LiaNdrY). Дефолтный режим маршрутизации начинался с <code>0.0.0.0/5</code> - на iOS этот блок ломал весь список маршрутов, и туннель вставал примерно через 10 секунд. На уже установленном сервере проще всего поставить в конфиге iOS-клиента <code>AllowedIPs = 0.0.0.0/0</code> (обычная переустановка с <code>--force</code> сохранённый список не меняет). Точечная правка с сохранением split-tunnel - в <a href="ADVANCED.md#faq-advanced-adv">ADVANCED.md</a>.
</details>

<details>
  <summary><strong>В: Почему порт 39743?</strong></summary>
  <b>О:</b> Это случайный порт из верхнего диапазона, выбранный как дефолт. Можно изменить при установке: <code>--port=N</code> (любой порт 1-65535). На мобильных сетях, где оператор режет незнакомые порты, часто выручает <code>443/udp</code> - его ставит флаг <code>--mobile</code> вместе с пресетом обфускации.
</details>

<details>
  <summary><strong>В: Нужен ли Perl на сервере?</strong></summary>
  <b>О:</b> Perl используется опционально для генерации <code>vpn://</code> URI (<code>.vpnuri</code> файлов). Если Perl отсутствует, <code>.conf</code> файлы создаются как обычно - ими можно пользоваться через импорт файла или QR-код. На Ubuntu и Debian Perl установлен по умолчанию.
</details>

<details>
  <summary><strong>В: Можно ли управлять сервером из своих скриптов или Telegram-бота?</strong></summary>
  <b>О:</b> Да. С v5.21.0 команды управления принимают флаг <code>--json</code> и отвечают одним JSON-объектом даже при сбое - его спокойно разберёт любой скрипт (<code>list</code>/<code>stats</code> отдают JSON-массивы давно). Формат обещаю не ломать: новые поля могут появляться, существующие не переименовываются. Для запусков без человека есть <code>--yes</code>, а строгий режим <code>AWG_STRICT_CONFIRM=1</code> заставляет команды вроде <code>remove</code> отказаться, если <code>--yes</code> забыли, вместо молчаливого согласия. Разбор формата - в <a href="ADVANCED.md#json-api-adv">ADVANCED.md → JSON-интерфейс</a>. Живой пример - Telegram-бот <a href="https://github.com/ekuraev/awgram">awgram</a>, он работает ровно через этот интерфейс.
</details>

<details>
  <summary><strong>В: Безопасно ли запускать скрипт повторно?</strong></summary>
  <b>О:</b> Да. Повторная установка поверх уже работающего сервиса требует флага <code>--force</code> (или <code>AWG_FORCE_REINSTALL=1</code>) - без него скрипт сообщит, что AmneziaWG уже установлен, и ничего не тронет. С <code>--force</code> серверный конфиг пересоздаётся, но существующие клиенты автоматически восстанавливаются из бэкапа: дефолтные клиенты (<code>my_phone</code>, <code>my_laptop</code>) пересоздаются, остальные - сохраняются.
</details>

> Больше ответов и решений см. в **[ADVANCED.md](ADVANCED.md)**.

---

<a id="nepoladki"></a>
## 🛠️ Устранение неполадок

1.  **Логи:** `/root/awg/install_amneziawg.log`, `/root/awg/manage_amneziawg.log`
2.  **Статус сервиса:** `sudo systemctl status awg-quick@awg0`
3.  **Статус AmneziaWG:** `sudo awg show`
4.  **Статус UFW:** `sudo ufw status verbose`
5.  **Диагностический отчет:** `sudo bash ./install_amneziawg.sh --diagnostic`
    Подробное описание содержимого отчета см. в [ADVANCED.md](ADVANCED.md#diagnostic-report-adv).

---

<a id="ekosistema"></a>
## 🌐 Экосистема

### Клиенты

> **Какой клиент выбрать?** Установите [**Amnezia VPN**](https://github.com/amnezia-vpn/amnezia-client/releases) (>= 4.8.12.7) - работает на всех платформах, поддерживает импорт `vpn://` URI.
> Для легковесного подключения (только `.conf`) используйте **AmneziaWG** для вашей платформы.

| Клиент | Платформа | AWG 2.0 | Тип | Примечание |
|--------|-----------|:-------:|-----|------------|
| **[Amnezia VPN](https://github.com/amnezia-vpn/amnezia-client/releases)** | Windows, macOS, Linux, Android, iOS | ✅ >= 4.8.12.7 | Официальный | **Рекомендуется.** Полнофункциональный, `vpn://` URI |
| [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-windows-client/releases) | Windows | ✅ >= 2.0.0 | Официальный | Легковесный tunnel manager, импорт `.conf` |
| [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-android) | Android | ✅ >= 2.0.0 | Официальный | Легковесный tunnel manager, импорт `.conf` |
| [AmneziaWG](https://apps.apple.com/app/amneziawg/id6478942365) | iOS | ✅ | Официальный | Легковесный tunnel manager, импорт `.conf` |
| [WG Tunnel](https://github.com/wgtunnel/android) | Android | ⚠️ частично | Сторонний, FOSS | Auto-tunneling, split tunnel, F-Droid |
| [VeilBox](https://github.com/artem4150/VeilBox) | Windows, macOS | ✅ | Сторонний, FOSS | Также поддерживает VLESS |

> [Полная таблица совместимости с AWG 1.x →](ADVANCED.md#client-compat-adv)

### Инструменты настройки

| Проект | Описание |
|--------|----------|
| [Junker](https://spatiumstas.github.io/junker/) | Веб-генератор подписей AmneziaWG от @spatiumstas - для ручной настройки без установочного скрипта |
| [AmneziaWG-Architect](https://vadim-khristenko.github.io/AmneziaWG-Architect/) | Веб-генератор CPS/мимикрии для AWG 2.0 от @Vadim-Khristenko ([GitHub](https://github.com/Vadim-Khristenko/AmneziaWG-Architect)) |

### Прошивки для роутеров

| Проект | Платформа | Описание |
|--------|-----------|----------|
| [AWG Manager](https://github.com/hoaxisr/awg-manager) | Keenetic (Entware) | Веб-интерфейс для управления AWG-туннелями на роутерах Keenetic |
| [AmneziaWG for Merlin](https://github.com/r0otx/asuswrt-merlin-amneziawg) | ASUS (Asuswrt-Merlin) | Аддон AWG 2.0 с веб-интерфейсом, GeoIP/GeoSite маршрутизация |

### Управление сервером

| Проект | Платформа | Описание |
|--------|-----------|----------|
| [amneziawg-manager](https://github.com/rockysys/amneziawg-manager) | macOS | Нативный GUI, управляет сервером по SSH через штатный manage - без веб-панели и демонов |
| [awgram](https://github.com/ekuraev/awgram) | Telegram | Бот на Rust: добавление/удаление клиентов, статистика, бэкап - через штатный manage |

<a id="upominaniya"></a>
<details>
<summary><strong>📰 Упоминания</strong></summary>

**📖 Гайды и туториалы**
- [Hetzner Community - Making a website accessible from restricted regions](https://community.hetzner.com/tutorials/making-website-accessible-from-restricted-regions) (cross-link в Resources)
- [Debian Forums - HowTo: Install AmneziaWG 2.0 on Debian 12/13](https://forums.debian.net/viewtopic.php?t=166105)
- [LowEndTalk - [Tutorial] One-command AmneziaWG VPN server install on Ubuntu / Debian / ARM](https://lowendtalk.com/discussion/217191)
- [AVA Hosting - Self-Hosted VPN: Setup AmneziaWG Easily (пошаговый гайд на основе установщика)](https://ava.hosting/information/amneziawg/)

**📰 Статьи и обзоры**
- [XDA Developers - «I found a self-hosted VPN that works where WireGuard gets blocked»](https://www.xda-developers.com/self-hosted-vpn-works-where-wireguard-gets-blocked/)
- [Pinggy - Top 5 Best Self-Hosted VPNs in 2026](https://pinggy.io/blog/top_5_best_self_hosted_vpns/)
- [gHacks Tech News - AmneziaWG 2.0](https://www.ghacks.net/2026/03/25/amnezia-releases-amneziawg-2-0-to-bypass-advanced-internet-censorship-systems/)

**📋 Каталоги и подборки**
- [VPN Статус - каталог AmneziaWG-сервисов и серверных решений](https://vpnstatus.site/protocols/amneziawg)
- [AlternativeTo - amneziawg-installer (42 альтернативы)](https://alternativeto.net/software/amneziawg-installer/about/)
- [LibHunt - #1 в категории Shell VPN](https://www.libhunt.com/r/amneziawg-installer)

**💬 Форумы и сообщества**
- [Qubes OS Forum - AmneziaWG for censored regions](https://forum.qubes-os.org/t/installation-of-amnezia-vpn-and-amnezia-wg-effective-tools-against-internet-blocks-via-dpi-for-china-russia-belarus-turkmenistan-iran-vpn-with-vless-xray-reality-best-obfuscation-for-wireguard-easy-self-hosted-vpn-bypass/39005)
- [Lemmy.world /c/selfhosted - amneziawg-installer announce (143 upvotes / 39 comments)](https://lemmy.world/post/45242153)

</details>

---

<a id="licenziya"></a>
## 📝 Лицензия и Автор

* **Автор скриптов:** @bivlked - [GitHub](https://github.com/bivlked)
* **Лицензия:** MIT - свободное ПО с открытым исходным кодом (см. `LICENSE`)

---

<p align="center">
  Проект пригодился - поставьте ⭐. Так его проще найти другим.
</p>

<p align="center">
  <a href="#top">↑ К началу</a>
</p>

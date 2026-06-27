# Roadmap

[Русская версия ниже](#дорожная-карта) | English first.

This page is a stable orientation point for where the project is heading. It is
intentionally high-level and theme-based rather than a dated release schedule,
so it does not go stale between releases.

The **living backlog** - concrete, prioritised, and open for discussion - is
tracked in issues and discussions, not here:

- [Roadmap & Public Backlog (issue #79)](https://github.com/bivlked/amneziawg-installer/issues/79) - current priorities and accepted ideas
- [Discussions](https://github.com/bivlked/amneziawg-installer/discussions) - proposals, carrier reports, Q&A
- [CHANGELOG.en.md](../CHANGELOG.en.md) - what already shipped

## Recently shipped

- AmneziaWG 2.0 support (H1-H4 ranges, S3/S4, I1-I5 CPS concealment).
- Dual-stack IPv6 inside the tunnel (`--allow-ipv6-tunnel`), split-tunnel aware.
- ARM64 / ARMv7 prebuilt kernel modules with DKMS fallback.
- ARM prebuilt `.deb` assets ship with a build manifest (installer tag,
  upstream commit, kernel, SHA256) and support pinning the upstream module
  revision.
- Ubuntu 24.04 / 25.10 / 26.04 and Debian 12 / 13 support.
- CI and docs-consistency gates around releases.
- Security and reliability hardening across installation and client management (atomic peer carry-over in the server config on `--force` reinstall, strict key permissions, careful temp-file and secret handling, Amnezia PPA GPG key pinned by full fingerprint).
- iOS clients work correctly in the default routing mode (Amnezia List + DNS): the bundled route list no longer stalls the iOS tunnel.
- Reliability on mobile, double-NAT and cascade paths: the TCP MSS is clamped to the tunnel size, which fixes the common PMTU-blackhole stall where large TCP pages and downloads hang when path-MTU discovery is blocked along the way.
- Full special-junk pass-through: all CPS concealment params `I1`-`I5` set in the server `awg0.conf` now reach clients (`.conf`, QR, `vpn://`), not just `I1`. Multi-packet concealment profiles can be configured server-side and distributed with `manage regen`.
- Companion guides: how the project compares to the official Amnezia app, and a two-server cascade with split-tunnel routing.
- Bug fixes: `install --force --port=N` now actually changes the server port; full-tunnel clients get `0.0.0.0/0, ::/0` so iOS AmneziaVPN accepts the all-traffic mode; the default client DNS is a `1.1.1.1, 1.0.0.1` pair.

## Under consideration

These are directions, not commitments. Priority and timing are decided in
issue #79 and the discussions.

- **Release integrity:** activate detached `minisign` signatures for the
  installer and helper scripts (design: [SIGNING_DESIGN.md](SIGNING_DESIGN.md);
  currently planned, not active - see [SECURITY.md](../SECURITY.md)).
- **ARM prebuilt reproducibility:** make a non-HEAD upstream kernel-module pin
  mandatory for release builds (the pin mechanism and the build manifest
  already ship; `HEAD` remains the default).
- **Carrier DPI tracking:** keep the operator parameter table current as
  regional blocking waves evolve (community reports welcome in Discussions).

## How to influence the roadmap

Open or comment on a [Discussion](https://github.com/bivlked/amneziawg-installer/discussions),
or add to [issue #79](https://github.com/bivlked/amneziawg-installer/issues/79).
Carrier reports (operator, region, working parameters) are especially useful.

---

<a id="дорожная-карта"></a>

# Дорожная карта

Эта страница - стабильная точка ориентации: куда движется проект. Она намеренно
тематическая, а не календарный график релизов, чтобы не устаревать между ними.

**Живой бэклог** - конкретный, приоритизированный и открытый для обсуждения -
ведётся в issues и discussions, а не здесь:

- [Roadmap & Public Backlog (issue #79)](https://github.com/bivlked/amneziawg-installer/issues/79) - текущие приоритеты и принятые идеи
- [Discussions](https://github.com/bivlked/amneziawg-installer/discussions) - предложения, отчёты по операторам, вопросы
- [CHANGELOG.md](../CHANGELOG.md) - что уже вышло

## Уже сделано

- Поддержка AmneziaWG 2.0 (диапазоны H1-H4, S3/S4, маскировка I1-I5 CPS).
- Dual-stack IPv6 внутри туннеля (`--allow-ipv6-tunnel`), с учётом split-tunnel.
- Готовые модули ядра ARM64 / ARMv7 с fallback на DKMS.
- ARM-сборки `.deb` поставляются с build-манифестом (тег установщика,
  upstream-коммит, ядро, SHA256) и поддерживают закрепление ревизии
  upstream-модуля.
- Поддержка Ubuntu 24.04 / 25.10 / 26.04 и Debian 12 / 13.
- CI и проверки согласованности документации вокруг релизов.
- Закалка безопасности и надёжности при установке и управлении клиентами (атомарный перенос peer-блоков в серверном конфиге при переустановке `--force`, строгие права на ключи, аккуратная работа с временными файлами и секретами, GPG-ключ Amnezia PPA закреплён по полному отпечатку).
- Клиенты iOS работают корректно в дефолтном режиме маршрутизации (Amnezia List + DNS): встроенный список маршрутов больше не подвешивает туннель на iOS.
- Надёжность на мобильных, double-NAT и каскадных путях: TCP MSS ограничивается под размер туннеля, что устраняет типичный PMTU-блэкхол, когда крупные TCP-страницы и закачки зависают при заблокированном по пути обнаружении path-MTU.
- Полный проброс special-junk: все CPS-параметры маскировки `I1`-`I5`, заданные в серверном `awg0.conf`, теперь доходят до клиентов (`.conf`, QR, `vpn://`), а не только `I1`. Многопакетные профили маскировки можно задать на сервере и раздать через `manage regen`.
- Сопутствующие гайды: сравнение проекта с официальным приложением Amnezia и каскад из двух серверов со split-tunnel-маршрутизацией.
- Багфиксы: `install --force --port=N` теперь действительно меняет порт сервера; полнотуннельные клиенты получают `0.0.0.0/0, ::/0`, чтобы iOS AmneziaVPN принимал режим всего трафика; DNS клиента по умолчанию - пара `1.1.1.1, 1.0.0.1`.

## На рассмотрении

Это направления, а не обязательства. Приоритет и сроки определяются в issue #79
и обсуждениях.

- **Целостность релизов:** активировать detached-подписи `minisign` для
  установщика и helper-скриптов (дизайн: [SIGNING_DESIGN.md](SIGNING_DESIGN.md);
  пока запланировано, не активно - см. [SECURITY.md](../SECURITY.md)).
- **Воспроизводимость ARM-сборок:** сделать закрепление не-HEAD ревизии
  upstream-модуля обязательным для релизных сборок (механизм закрепления и
  build-манифест уже поставляются; по умолчанию остаётся `HEAD`).
- **Отслеживание DPI операторов:** держать таблицу параметров операторов
  актуальной по мере новых волн региональных блокировок (отчёты приветствуются в
  Discussions).

## Как повлиять на дорожную карту

Откройте или прокомментируйте [Discussion](https://github.com/bivlked/amneziawg-installer/discussions)
либо дополните [issue #79](https://github.com/bivlked/amneziawg-installer/issues/79).
Особенно полезны отчёты по операторам (оператор, регион, рабочие параметры).

# CHANGELOG

## v5.1 – 2025‑04‑30
* Добавлен профиль `azure` (`--profile=azure`): fw=none, disable‑ipv6, cleanup, non‑interactive.
* Раздельные флаги `--disable-ipv6`, `--with-net2ban`; `--hardening` = оба вместе.
* Проверка отсутствия UFW в `manage_amneziawg.sh regen-fw`.
* Явный `errtrace`, косметика case‑веток.
* Документация вынесена в `docs/`, README в корне.

## v5 – 2025‑04‑29
* Полный рефактор: state‑machine, self‑update, split‑туннель.
* Файрволы: ufw / firewalld / iptables / none.
* Workaround бага `awgcfg.py`.

## v4 – 2024‑12‑10
* Первая публичная версия скрипта установки Ubuntu 24.04.
# ADVANCED.md — опции, профили, устранение неполадок

## 1. CLI‑флаги установщика
| Флаг | Аргумент | По умолчанию | Описание |
|------|----------|--------------|----------|
| `--fw` | ufw \| firewalld \| iptables \| none | ufw | Бэкенд файрвола |
| `--allowed-ips` | default \| split | default | Профиль маршрутизации |
| `--disable-ipv6` | – | off | Полностью отключает IPv6 на сервере |
| `--with-net2ban` | – | off | Устанавливает net2ban и включает сервис |
| `--hardening` | – | off | Эквивалент двух предыдущих флагов |
| `--profile` | azure | – | Предустановленный набор для Azure |
| `--non-interactive` | – | off | Без вопросов (CI/CD) |
| `--self-update` | – | – | Обновить сам установщик |

## 2. Профиль `azure`
Активация: `--profile=azure`
* `fw=none`
* `--disable-ipv6`
* `--non-interactive`
* Автоматическая очистка пакетов (`man-db`, `snapd`, apt‑кеш)

## 3. Известные баги
| ID | Симптом | Обход |
|----|---------|-------|
| **BUG‑awgcfg** | `awgcfg.py -c -q` удаляет `awgsetup_cfg.init` | Скрипты временно перемещают файл и возвращают. |
| **iptables wait-interval** | Спам `Ignoring deprecated --wait-interval` | Параметр удалён в v5. |

## 4. Примеры
```bash
# Azure mini‑VM
bash install_amneziawg.sh --profile=azure

# Firewalld + split туннель + net2ban
bash install_amneziawg.sh --fw=firewalld --allowed-ips=split --with-net2ban
```

## 5. CI: ShellCheck + shfmt
```yaml
name: shell lint
on: [push]
jobs:
  shlint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ludeeus/action-shellcheck@v2
      - run: sudo apt-get install -y shfmt && shfmt -d .
```
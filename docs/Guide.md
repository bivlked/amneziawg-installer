# Руководство AmneziaWG

## Подготовка
* VPS Ubuntu 24.04/25.04 (amd64/arm64)
* UDP‑порт 51820 открыт
* root‑доступ по SSH

## Установка
```bash
curl -fsSL https://raw.githubusercontent.com/bivlked/amneziawg-installer/version-5/install_amneziawg.sh | bash
```
**Azure профиль**
```bash
bash install_amneziawg.sh --profile=azure
```

## Добавление клиента
```bash
manage_amneziawg.sh add alice > alice.conf
qrencode -t ansiutf8 < alice.conf
```

## Обновление
`install_amneziawg.sh --self-update`

## Backup
```bash
tar czf awg-backup.tar.gz /etc/wireguard /root/awg
```

## Удаление
```bash
systemctl stop wg-quick@awg0
apt-get purge wireguard wireguard-tools -y
rm -rf /etc/wireguard /root/awg /root/.amwg-installer
```
# AmneziaWG Installer ![branch](https://img.shields.io/badge/branch-version--5.1-blue)

> Установщик VPN‑сервера AmneziaWG для Ubuntu 24.04+/arm64 & amd64.

## 🚀 Быстрый старт
```bash
curl -fsSL https://raw.githubusercontent.com/bivlked/amneziawg-installer/version-5/install_amneziawg.sh | bash
```

## Профиль Azure
Мини‑VM в Microsoft Azure:
```bash
bash install_amneziawg.sh --profile=azure
```
Скрипт отключит IPv6, не установит файрвол, почистит лишние пакеты.

## Рекомендуемый хостинг
<a id="recomend-hosting"></a>
## 🚀 Рекомендация хостинга

Для стабильной работы VPN‑сервера с высокой пропускной способностью важен надежный хостинг с хорошим каналом.

Мы протестировали и рекомендуем [**FreakHosting**](https://freakhosting.com/clientarea/aff.php?aff=392). В частности, их линейка **BUDGET VPS** предлагает отличное соотношение цены и качества.

* **Рекомендуемый тариф:** **BVPS-2**
* **Характеристики:** 2 vCPU, 2 GB RAM, 40 GB NVMe SSD.
* **Ключевое преимущество:** порт **10 Gbps** с **неограниченным трафиком**. Идеально для VPN!
* **Цена:** Всего **€25 в год** (около 2200 руб.).

Этой конфигурации более чем достаточно для комфортной работы AmneziaWG с большим количеством подключений и высоким трафиком.

## Документация
* [Guide](docs/Guide.md) — подробное руководство
* [ADVANCED](docs/ADVANCED.md) — все CLI‑флаги, Azure‑профиль, баги
* [CHANGELOG](docs/CHANGELOG.md)
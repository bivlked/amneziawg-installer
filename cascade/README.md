# cascade/ru.zone - снимок российских IP-сетей / Russian IP networks snapshot

## Русский

`ru.zone` - снимок агрегированного списка российских (RU) IP-сетей. Его использует
скрипт каскадного сплит-роутинга `awg-routing.sh` (см. [CASCADE.md](../CASCADE.md)).

При каждом запуске скрипт скачивает актуальный список с ipdeny.com. Этот снимок в
репозитории - запасной вариант: если на свежем сервере ipdeny.com недоступен (а
локальной копии ещё нет), скрипт берёт файл отсюда через `raw.githubusercontent.com`,
и каскад всё равно поднимается с рабочим списком RU-сетей.

- Источник: https://www.ipdeny.com/ipblocks/ (агрегированная зона `ru-aggregated.zone`)
- Дата снимка: 2026-07-06
- Сетей: 8626 (IPv4 CIDR, по одной на строку, окончания строк LF)
- Данные агрегированы из публичных записей о распределении адресов RIR, редистрибуция разрешена.

### Как обновить снимок

Обновляйте примерно раз в 6-12 месяцев (российские диапазоны меняются медленно):

```bash
curl -fsS -o cascade/ru.zone https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone
```

Закоммитьте обновлённый файл и поправьте дату снимка выше.

## English

`ru.zone` is a snapshot of the aggregated list of Russian (RU) IP networks. It is used
by the cascade split-routing script `awg-routing.sh` (see [CASCADE.en.md](../CASCADE.en.md)).

The script downloads the live list from ipdeny.com on every run. This bundled snapshot is
a fallback: if ipdeny.com is unreachable on a fresh server (with no locally cached copy yet),
the script fetches this file over `raw.githubusercontent.com`, so the cascade still comes up
with a working RU network list.

- Source: https://www.ipdeny.com/ipblocks/ (aggregated zone `ru-aggregated.zone`)
- Snapshot date: 2026-07-06
- Networks: 8626 (IPv4 CIDR, one per line, LF line endings)
- The data is aggregated from public RIR allocation records; redistribution is allowed.

### Refreshing the snapshot

Refresh roughly every 6-12 months (RU allocations change slowly):

```bash
curl -fsS -o cascade/ru.zone https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone
```

Commit the updated file and update the snapshot date above.

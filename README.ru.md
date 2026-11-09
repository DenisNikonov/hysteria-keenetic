# hysteria-keenetic

[English](README.md) | [Русский](README.ru.md)

Выборочная маршрутизация трафика через VPN на роутерах Keenetic с Entware. Через VPN идёт только трафик к заблокированным доменам — всё остальное напрямую.

Под капотом [sing-box](https://sing-box.sagernet.org/) с [Hysteria 2](https://v2.hysteria.network/) (QUIC-based). Разрабатывалось для российских провайдеров, но подходит под любые гео-ограничения.

## Как это работает

```
Устройство в LAN
    │
    ▼  DNS-запрос (любой адрес, порт 53)
iptables mangle TPROXY ──► sing-box DNS handler (:5302)
    │
    ▼
sing-box ──► dnsmasq (:5300)
    ├── резолвит через dnscrypt-proxy (:5301) ──► SOCKS5 ──► VPS ──► DNS
    ├── домен в списке? → добавляет IP в ipset "unblock"
    └── возвращает ответ клиенту
    │
    ▼  TCP/UDP соединение
iptables PREROUTING ──► проверяет ipset "unblock"
    ├── TCP: nat REDIRECT ──► sing-box (:2500) ──► Hysteria 2 ──► VPS
    ├── UDP: mangle TPROXY ──► sing-box (:2501) ──► Hysteria 2 ──► VPS
    └── IP не в наборе → напрямую
```

Почему так:
- **DNS через TPROXY и sing-box.** Весь UDP DNS из LAN перехватывается через TPROXY и пересылается в dnsmasq. Работает независимо от того, какой DNS-сервер настроен на устройстве (8.8.8.8, 1.1.1.1, IP роутера и т.д.) — никакой ручной настройки DNS на устройствах не нужно. Используем TPROXY вместо REDIRECT, потому что на ядре Keenetic 4.9 `iptables nat REDIRECT` не доставляет UDP-пакеты на нелокальные IP. TCP DNS по-прежнему через nat REDIRECT (для TCP работает нормально).
- **REDIRECT для TCP, TPROXY для UDP.** На ядре 4.9 у TPROXY баг с долгоживущими TCP-соединениями — ломает SSE streaming, Claude Code и т.п. Для UDP (QUIC) проблем нет, поэтому он идёт через TPROXY как есть.
- **DNS через VPS.** CDN (YouTube, Google) отдаёт IP ближайший к тому, кто резолвит. Если резолвить локально — получишь IP для своего провайдера, а трафик пойдёт через VPS в другой стране. Результат — тормоза. Поэтому DNS тоже идёт через VPS.
- **Динамический ipset.** IP добавляются в момент DNS-запроса, никаких статических списков которые протухают.

## Требования

- Роутер Keenetic с [Entware](https://github.com/Entware/Entware/wiki)
- VPS (Linux, минимум 512MB RAM, 1 ядро хватит) с открытым UDP-портом 443
- SSH-доступ к роутеру

### Модули Netfilter (обязательно)

Без этого ipset и перенаправление трафика не заведутся.

Веб-интерфейс Keenetic → **Управление** → **Параметры системы** → **Изменить набор компонентов** → **Пакеты OPKG** → **Модули ядра подсистемы Netfilter** → включить → перезагрузить роутер.

## Быстрый старт

### 1. Сервер Hysteria 2 на VPS

Два варианта: с доменом или без.

<details>
<summary><b>Вариант А: С доменом (Let's Encrypt)</b></summary>

```yaml
# /etc/hysteria/config.yaml
listen: :443

acme:
  domains:
    - your-domain.com
  email: your@email.com

auth:
  type: password
  password: ваш-надёжный-пароль

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
```
</details>

<details>
<summary><b>Вариант Б: Без домена (самоподписанный сертификат)</b></summary>

```bash
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
  -subj "/CN=bing.com" -days 36500
chmod 644 /etc/hysteria/server.key
```

```yaml
# /etc/hysteria/config.yaml
listen: :443

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: ваш-надёжный-пароль

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
```
</details>

Установка:
```bash
bash <(curl -fsSL https://get.hy2.sh/)
systemctl enable --now hysteria-server
```

### 2. Роутер

```bash
ssh root@ip-роутера
cd /tmp
curl -L -o hk.tar.gz https://github.com/DenisNikonov/hysteria-keenetic/archive/main.tar.gz
tar xzf hk.tar.gz
cd hysteria-keenetic-main

cp config.example config
vi config
# HY_SERVER=ip-vps:443       (обязательно)
# HY_PASSWORD=пароль          (обязательно)
# HY_TLS_INSECURE=1           (если самоподписанный сертификат)

sh install.sh
hysteria-keenetic start
```

### 3. Проверка

```bash
hysteria-keenetic status
```

Откройте заблокированный сайт с любого устройства в сети. Настройка DNS на клиентах не нужна — DNS перехватывается прозрачно независимо от того, какой DNS-сервер использует устройство (8.8.8.8, 1.1.1.1, IP роутера и т.д.).

## Конфигурация

Файл: `/opt/etc/hysteria-keenetic/config`

### Основные

| Параметр | Описание | Пример |
|----------|----------|--------|
| `HY_SERVER` | Адрес сервера | `1.2.3.4:443` |
| `HY_PASSWORD` | Пароль | |
| `SERVICES` | Сервисы через запятую | `Youtube,Google,Openai` |

### Hysteria 2

| Параметр | По умолчанию | Описание |
|----------|-------------|----------|
| `HY_BW_UP` | `50 mbps` | Upload (Brutal CC). `0` = BBR |
| `HY_BW_DOWN` | `100 mbps` | Download (Brutal CC). `0` = BBR |
| `HY_TLS_INSECURE` | `0` | `1` для самоподписанных сертификатов |
| `HY_OBFS_PASSWORD` | *(пусто)* | Salamander обфускация (см. ниже) |
| `HY_QUIC_TUNING` | `0` | `1` для больших QUIC-буферов на быстрых линиях |

### Прочее

| Параметр | По умолчанию | Описание |
|----------|-------------|----------|
| `ROUTE_MODE` | `selective` | `selective` = только заблокированные домены через VPN; `all` = весь трафик через VPN; `except-ru` = российские IP напрямую, остальное через VPN |
| `FULL_VPN_DEVICES` | *(пусто)* | Список устройств LAN (MAC или IP через запятую), весь трафик которых идёт через VPN независимо от `ROUTE_MODE` |
| `FORCE_DNS` | `1` | Блокировать DoH/DoT чтобы клиенты не обходили наш DNS |
| `LAN_IF` | `br0` | LAN-интерфейс(ы) через запятую (например `br0,nwg6`, чтобы маршрутизировать и клиентов WireGuard-сервера Keenetic) |
| `DNSMASQ_PORT` | `5300` | Порт dnsmasq |
| `FWMARK` | `2` | Метка для UDP policy routing |
| `ROUTE_TABLE` | `101` | Таблица маршрутизации |
| `CRON_SCHEDULE` | `0 4 * * *` | Расписание автообновления списков |

### Сервисы

Большинство списков берётся из [DomainMapper](https://github.com/Ground-Zerro/DomainMapper): Youtube, Google, Facebook, Tik-Tok, Twitter, Openai, Instagram, Discord, Twitch, Telegram, Netflix, Bing, Adobe, Apple, Jetbrains, Xbox, Windsurf, Roblox, Zscaler, Torrent Trackers, Online movie theaters, Search engines, Github Copilot.

Плюс [Antifilter community edition](https://community.antifilter.download/), [ITDog Inside/Outside](https://github.com/itdoginfo/allow-domains), [WhatsApp](https://github.com/HybridNetworks/whatsapp-cidr).

### Свои домены и IP

Файл `custom-domains.txt` (сервис `custom` должен быть в `SERVICES`):

```
# Домены — резолвятся dnsmasq, IP попадают в ipset
my-blocked-site.com
another-site.io

# IP/CIDR — добавляются в ipset напрямую
# Для сервисов с выделенными диапазонами, которые не поймать через DNS
160.79.104.0/23
```

```bash
hysteria-keenetic update
```

## Команды

```bash
hysteria-keenetic start       # Запуск
hysteria-keenetic stop        # Остановка + очистка iptables
hysteria-keenetic restart     # Перезапуск
hysteria-keenetic update      # Обновить списки доменов
hysteria-keenetic upgrade     # Обновить sing-box
hysteria-keenetic self-update # Обновить всё (скрипты + sing-box + домены)
hysteria-keenetic status      # Статус компонентов
```

## Дополнительно

### Полный VPN (ROUTE_MODE)

По умолчанию через VPN идёт только трафик к заблокированным доменам (`ROUTE_MODE=selective`). Чтобы весь трафик шёл через VPN:

```
ROUTE_MODE=all
```

В режиме `all` IP VPN-сервера и приватные сети (10.x, 192.168.x и т.д.) автоматически исключаются, чтобы не было петель маршрутизации. Полезно, когда нужно, чтобы весь трафик шёл от IP VPN-сервера.

`ROUTE_MODE=except-ru` — обратный `selective` режим: трафик к российским IP идёт напрямую через провайдера, всё остальное — через VPN. Российские сервисы, блокирующие зарубежные IP (банки, Госуслуги), видят домашний IP; зарубежные — IP VPS.

- Список RU-сетей (~8.7 тыс. CIDR) берётся из [ipverse/rir-ip](https://github.com/ipverse/rir-ip), запасной источник — [ipdeny](https://www.ipdeny.com/). Хранится в `ru-ips.lst` и обновляется вместе с доменами по cron (`hysteria-keenetic update`). Если загрузка не удалась или список подозрительно короткий, остаётся предыдущий.
- Домены из `SERVICES` идут через VPN, даже если резолвятся в российские IP (например, CDN-кеши внутри российских провайдеров).
- RU-трафик не проходит через sing-box и не теряет скорость. Весь зарубежный трафик идёт через CPU роутера и VPS.

### Полный VPN для отдельных устройств (FULL_VPN_DEVICES)

Чтобы весь трафик конкретных устройств (например, телевизора или приставки) шёл через VPN, а остальная сеть оставалась в режиме selective, перечислите их в `FULL_VPN_DEVICES` (через запятую). Каждый элемент — MAC-адрес (рекомендуется — не зависит от смены IP по DHCP) или IP:

```
FULL_VPN_DEVICES="54:b7:bd:60:09:64"
FULL_VPN_DEVICES="54:b7:bd:60:09:64,192.168.1.50"
```

Такие устройства полностью игнорируют список доменов — каждое их соединение идёт через туннель. Трафик в локальную сеть и к VPN-серверу остаётся прямым (без петель маршрутизации), DNS по-прежнему обрабатывается локальным резолвером. MAC устройства можно найти в веб-интерфейсе Keenetic (список устройств) или через `cat /proc/net/arp` по SSH. После изменения перезапустите сервис: `hysteria-keenetic restart`.

### Обновление

`self-update` скачивает последние скрипты с GitHub, обновляет sing-box через opkg, обновляет списки доменов и перезапускает сервис если он был запущен:

```bash
hysteria-keenetic self-update
```

Также доступны отдельные команды: `update` — только списки доменов, `upgrade` — только sing-box.

### Обфускация (Salamander)

Нужна, если провайдер режет QUIC через DPI. Признаки: частые `client disconnected` в логах Hysteria, соединения рвутся через несколько секунд, скорость скачет или падает в ноль.

Добавьте в конфиг **сервера**:
```yaml
obfs:
  type: salamander
  salamander:
    password: ваш-пароль-обфускации
```

И на **роутере** в config:
```
HY_OBFS_PASSWORD=ваш-пароль-обфускации
```

Пароли должны совпадать. После этого QUIC-трафик выглядит как случайный UDP.

### Большие QUIC-буферы

Для каналов >50 Мбит/с можно добавить в конфиг сервера:

```yaml
quicConfig:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
```

И `HY_QUIC_TUNING=1` на роутере.

### Блокировка DoH/DoT

При `FORCE_DNS=1` (по умолчанию) блокируется DNS-over-TLS (порт 853) и DNS-over-HTTPS к известным провайдерам (Google, Cloudflare, Quad9, OpenDNS, AdGuard, CleanBrowsing). Без этого браузеры и устройства с зашитым DoH будут резолвить мимо нашего dnsmasq и ipset не заполнится.

### Аппаратный NAT (FASTNAT)

Keenetic использует аппаратное ускорение NAT, которое обходит iptables для уже установленных соединений. При запуске делается `conntrack -F` — все соединения переустанавливаются и проходят через новые правила. Если после старта что-то не работает — попробуйте `conntrack -F` вручную и сбросьте DNS-кэш на клиенте.

### Прогрев DNS

При старте популярные домены из включённых сервисов резолвятся заранее, чтобы ipset был заполнен до того, как клиенты начнут ходить по кэшированным DNS-записям.

### Обновление прошивки Keenetic

Entware живёт на флешке/разделе opt — обновление прошивки его не затрагивает. Но если роутер сбросился до заводских настроек — модули Netfilter нужно включить заново.

## Решение проблем

**"No chain/target/match by that name"** — модули Netfilter не включены. См. выше.

**Видео тормозит** — проверьте `hysteria-keenetic status`. Если VPS далеко, попробуйте ближе (Амстердам, Франкфурт вместо Лондона). Включите обфускацию если провайдер режет QUIC. На быстрых каналах попробуйте `HY_QUIC_TUNING=1`.

**Сайт не открывается через VPN** — добавьте в `custom-domains.txt` и сделайте `hysteria-keenetic update`. Для сервисов с выделенными IP (не обнаруживаемыми через DNS) — добавьте CIDR.

**"HY_SERVER is not configured"** — `vi /opt/etc/hysteria-keenetic/config`

**Диагностика:**
```bash
# DNS через dnsmasq
dig youtube.com @127.0.0.1 -p 5300

# IP в ipset?
ipset test unblock 142.250.74.14

# VPN работает?
curl --socks5 127.0.0.1:1080 https://ifconfig.me

# Логи
logread | grep hysteria-keenetic
logread | grep hy-update
```

## Удаление

```bash
sh /opt/etc/hysteria-keenetic/uninstall.sh
```

## Ссылки

- [sing-box](https://sing-box.sagernet.org/) — прокси-платформа
- [Hysteria 2](https://v2.hysteria.network/) — QUIC-based VPN
- [DomainMapper](https://github.com/Ground-Zerro/DomainMapper), [antifilter.download](https://community.antifilter.download/), [ITDog](https://github.com/itdoginfo/allow-domains) — списки доменов
- [DNSCrypt](https://github.com/DNSCrypt/dnscrypt-proxy) — DNS-прокси

## Лицензия

[MIT](LICENSE)
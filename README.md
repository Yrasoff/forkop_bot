# 🤖 podkop_bot v0.15.3

Telegram-бот для удалённого управления [podkop](https://github.com/itdoginfo/podkop) — сервисом маршрутизации трафика для OpenWrt на базе sing-box.

Поддерживает все три варианта podkop: **[original](https://github.com/itdoginfo/podkop)** (itdoginfo), **[netshift aka evolution](https://github.com/yandexru45/podkop-evolution)** (yandexru45) и **[plus](https://github.com/ushan0v/podkop-plus)** (ushan0v). Позволяет управлять службой и выполнять диагностику прямо из Telegram — без доступа к LuCI и SSH.

> 📋 История изменений — [CHANGELOG_RUS.md](CHANGELOG_RUS.md)
> 
> 🗺️ Структура меню и описание всех карточек — [BOT_STRUCTURE.md](BOT_STRUCTURE.md)

---

## 🚀 Быстрая установка

```sh
wget -O /tmp/install_podkop_bot.sh https://raw.githubusercontent.com/Medvedolog/podkop_bot/main/install.sh
ash /tmp/install_podkop_bot.sh
```

Установщик поддерживает 4 режима:

1. **Update** — обновить скрипт, сохранить конфиг
2. **Reinstall** — переустановить с новыми настройками
3. **Exit** — выйти без изменений
4. **Uninstall** — полное удаление бота (двойное подтверждение: `YES` → `REMOVE`)

---

## 📋 Требования

* OpenWrt 24.x / 25.x или ImmortalWrt
* Установленный и настроенный podkop (original, netshift/evolution или plus) 0.7.x с включённым Mixed Proxy Port
* Пакеты: `curl`, `jq` (устанавливаются автоматически)
* Токен Telegram-бота (получить у [@BotFather](https://t.me/BotFather))
* TG User ID администратора(-ов) — например через [@Getmyid_Work_Bot](https://t.me/Getmyid_Work_Bot)

---

## ✨ Что умеет бот

### 🔀 Поддержка вариантов podkop

Начиная с v0.15.0 бот автоматически определяет установленный вариант и адаптирует все операции:

* **original** ([itdoginfo/podkop](https://github.com/itdoginfo/podkop)) — полная поддержка
* **evolution** ([yandexru45/podkop-evolution](https://github.com/yandexru45/podkop-evolution)) — полная поддержка включая subscription
* **plus** ([ushan0v/podkop-plus](https://github.com/ushan0v/podkop-plus)) — расширенная поддержка Plus CLI:
  * Версии zapret / byedpi, наличие обновлений
  * Меню секций zapret и byedpi с валидацией стратегий
  * URLTest Filters — фильтрация серверов по стране, имени и regex прямо из бота
  * Трафик и срок действия подписки (`📊 18.5 GB / ∞ · exp 28.08.2026`) в Outbounds
  * Состояние фильтрации outbound'ов (`⊘` у серверов, исключённых URLTest-фильтром)
  * Закрытие всех соединений (Close Connections) из Runtime Info

### 🛡️ Управление сервисом

* Статус `podkop` и `sing-box` в реальном времени
* Запуск / остановка / перезагрузка `podkop`
* Включение / выключение автозапуска
* Обновление `podkop` до последней версии
* **Обновление самого бота** прямо из меню Maintenance (без SSH)

  * перед обновлением бот показывает доступную версию и краткий блок **What's New**
  * даёт ссылку на changelog
  * **Force Update** — принудительная переустановка текущей версии для применения патчей
* **Перезагрузка роутера** с двойным подтверждением (кнопка + ввод `YES`)

### 🌐 Outbound Selector / URLTest / Subscription

* Просмотр списка outbound'ов с задержкой, типом протокола и страной (флаг)
* Переключение активного outbound
* Активный outbound выделен маркером `▶`
* Тест задержки всех outbound'ов одной кнопкой
* Добавление и удаление ссылок (`vless://`, `hy2://`, `ss://`, `trojan://`, `vmess://`, `socks5://`)
* Удаление по `server:port` — надёжно для всех протоколов
* Заголовок карточки отражает режим: **Outbound Selector**, **URLTest Outbounds** или **Subscription Outbounds**
* **Клонирование ссылок из Selector в URLTest** одной кнопкой
* Предупреждение при переключении в URLTest, если список ссылок пуст
* **Single URL Proxy** — отдельный режим для одной ссылки
* Для подписочных секций в шапке карточки: URL подписки + трафик и срок действия (Plus)

### ⚙️ Настройки секций podkop

* Переключение между секциями (`main`, `antiz` и любыми другими) с подтверждением
* **Корректная работа с несколькими секциями** — данные всегда читаются из активной секции
* Тип подключения (`proxy` / `vpn` / `block` / `direct`)
* Режим прокси (`selector` / `urltest` / `url` / `outbound`) — переключение через меню
* **Защита при переключении в URL-режим** — бот удерживает reload до получения ссылки
* **Auto-assign порта Mixed Proxy** при включении
* URLTest: testing URL, интервал проверки, допуск задержки, список ссылок
* **URLTest Filters** (только Plus): режим фильтрации, определение страны, скрытие отфильтрованных, списки исключений по стране и имени outbound
* Domain Resolver: включение, тип DNS, сервер — для каждой секции отдельно
* Outbound Interface: привязка секции к конкретному интерфейсу

### 📋 Маршрутизация и списки

* **Service Lists** — готовые наборы: `russia_inside`, `telegram`, `twitter`, `cloudflare` и др.
* **Domain List URLs / Subnet List URLs** — внешние списки по ссылке (URL на `.lst`-файл)
* **Devices → Tunnel** — устройства, чей весь трафик идёт через туннель (Fully Routed IPs)
* **Devices → Bypass** — устройства, которые ходят напрямую мимо туннеля (Excluded IPs)
* **My Domains / My Subnets** — собственные домены и подсети вручную (постраничный редактор)

### 🌍 DNS и YACD

* Тип DNS (`udp` / `doh` / `dot`), сервер, bootstrap DNS
* YACD: включение, WAN-доступ, управление секретным ключом

### 🔧 Настройки Bad WAN

* Включение мониторинга
* Список отслеживаемых интерфейсов
* Задержка перезагрузки

### 🤖 Управление транспортом бота

* **Transport Policy**: `auto` / `socks` / `direct` — с описанием рисков и подтверждением
* **Fallback SOCKS** (`tier2_N`): добавление, удаление, тест доступности всех tier'ов
* Активный tier выделен маркером `◀ active`
* Custom Proxy (tier3)
* Bind Interface — привязка исходящего интерфейса бота
* **Автодобавление mixed_proxy других секций** как fallback tier'ов
* **Admins** — см. раздел ниже

### 👤 Управление администраторами

Список администраторов бота редактируется прямо в Telegram — SSH и UCI не нужны.

Открыть: **Bot Settings → 👤 Admins**

* **Основной admin** (`chat_id`) — отображается с 🔒, удалить нельзя
* **Дополнительные admins** — добавить User ID кнопкой **➕ Add Admin**, удалить с подтверждением
* **Anonymous group admins** — кнопка-переключатель 🟢/🔴
* **🤖 Bot Info & Invite** — `@username`, ID, версия + инструкция для группы

> После добавления бота в группу достаточно нажать **➕ Add Admin** и ввести `chat_id` группы.

### 📊 Диагностика и мониторинг

* **Status**: агрегированный диагноз (`✅ Podkop is running` / `⚠️ limited` / `❌ action required`), системная информация — Host, модель устройства, uptime, RAM, CPU, WAN + внешний IP, версии
* **Tunnel Health**: статус `sing-box`, `nftables`, режим, WAN, transport latency по tier'ам

  * два независимых TG health-чека: `TG direct` и `TG tunnel SOCKS5`
  * блок **Active outbounds by section** — задержка и TG-достижимость для каждой секции
  * **GitHub Connectivity** — проверка `api.github.com` и `raw.githubusercontent.com` напрямую (WAN) и через SOCKS с реальной задержкой; показывает можно ли получить обновления из-под блокировок
* **Runtime Info**: подключения, трафик, активный outbound, задержка, маршрут бота
* **Diagnostics** (единый хаб): Tunnel Health, Upstream Health, Global Check, Internal Diagnostics, Support Bundle, Active Probe
* **Active Outbound Probe**: полная диагностика через текущий активный outbound

  * Exit IP + GeoIP (ipapi.co + Cloudflare + Google)
  * YouTube country hint
  * Доступность сервисов: YouTube, Telegram API, ChatGPT, Claude.ai, Gemini, Discord
  * Двухэтапный тест скорости: 32 KB (детект РКН-обрыва) + 1 MB замер
* **Support Bundle**: UCI-конфиг, маршруты, nft, syslog одной кнопкой

### 🔔 Watchdog и алерты

* Мониторинг `sing-box` (алерт при остановке и восстановлении)
* Мониторинг SOCKS upstream с гистерезисом
* **Алерт смены прокси**: `🔀` с дебаунсом 120 сек — серия переключений группируется в одно сообщение, без спама при URLTest-флаппинге
* TG connectivity мониторинг (`direct` + `tunnel SOCKS5` + `tier2` раздельно)
* Периодическая проверка задержки всех SOCKS tier'ов
* Alerts при деградации маршрута бота на Direct или Emergency IPs
* **Аварийные Telegram IP** через DoH-discovery — список обновляется каждые 6 часов из трёх DoH-провайдеров (Cloudflare, Google, Quad9) с проверкой принадлежности AS62041; статичный список остаётся как fallback
* Постоянная навигационная клавиатура `🏠 Menu | 📊 Status` — доступна всегда, в том числе при watchdog-алертах

### 📡 Транспортная цепочка бота

Бот сам работает через многоуровневый fallback при блокировках:

```text
tier1   → Podkop SOCKS5 (основной туннель, primary proxy-секция)
tier2_N → Fallback SOCKS list (socks5:// / socks5h://) + авто-секции с mixed_proxy
tier3   → Custom Proxy
tier4   → Direct
tier5   → Emergency Telegram IPs (обновляются через DoH)
```

Sticky-routing, Recovery Mode и IPC между watchdog и main loop позволяют боту оставаться доступным даже при проблемах с основным туннелем. После восстановления `podkop` бот возвращается на `tier1` в течение одного health interval (обычно ≤60 сек).

---

## 👥 Несколько роутеров и администраторов

Поддерживается схема с несколькими ботами в одном Telegram supergroup:

* каждый роутер — отдельный bot token
* несколько `admin_ids` (добавляются через `uci add_list` или через меню бота)
* все алерты содержат префикс `[hostname]` для идентификации роутера
* поддерживаются anonymous admins в группах через `ALLOW_ANON_ADMINS`

---

## 🔧 Ручная установка

```sh
# Скачать скрипт
wget -O /usr/bin/podkop_bot https://raw.githubusercontent.com/Medvedolog/podkop_bot/main/podkop_bot.sh
chmod +x /usr/bin/podkop_bot

# Настроить UCI
uci set podkop_bot.settings=settings
uci set podkop_bot.settings.bot_token="ВАШ_ТОКЕН"
uci set podkop_bot.settings.chat_id="ВАШ_CHAT_ID"
uci commit podkop_bot

# Запустить
/usr/bin/podkop_bot &
```

---

## 📁 Структура конфига UCI

```text
/etc/config/podkop_bot
├── settings.bot_token       — токен бота
├── settings.chat_id         — основной chat_id (куда слать алерты)
├── settings.admin_ids       — список user_id (через uci add_list)
├── settings.transport       — auto / socks / direct
├── settings.fallback_socks  — list socks5h://...
├── settings.custom_proxy    — кастомный прокси (tier3)
├── settings.bind_interface  — привязка к интерфейсу
├── settings.health_interval — интервал watchdog (сек, default 60)
├── settings.alert_notify    — 1/0 алерты watchdog
└── settings.startup_notify  — 1/0 уведомление при старте
```

> **Важно:** `admin_ids` добавляются через `uci add_list`, а не через `uci set` — иначе несколько ID не сохранятся корректно.

```sh
uci add_list podkop_bot.settings.admin_ids="123456789"
uci add_list podkop_bot.settings.admin_ids="987654321"
uci commit podkop_bot
```

---

## 📂 Файлы проекта

| Файл | Описание |
|------|----------|
| `podkop_bot.sh` | Основной скрипт бота |
| `install.sh` | Установщик / обновление / удаление |
| `BOT_STRUCTURE.md` | [Структура меню](BOT_STRUCTURE.md) — все карточки, строки и кнопки |
| `CHANGELOG.md` | История изменений (EN) |
| `CHANGELOG_RUS.md` | История изменений (RU) |
| `version.txt` | Актуальная версия для self-update |
| `highlights.txt` | Краткое описание новой версии для карточки обновления |

---

## ⚠️ Известные особенности

**OpenWrt 24.10.x — баг в BusyBox `tr`:**
Символьный класс `[:space:]` обрабатывается некорректно и удаляет букву `e` (`0x65`). Исправлено в `v0.13.90` заменой на явное перечисление символов `\n\r\t `. Затрагивает сборки OpenWrt 24.10.x вне зависимости от архитектуры.

**Podkop Plus — UCIполя для списков:**
`uci -q get` на list-полях (`subscription_urls`, `selector_proxy_links` и др.) в BusyBox ash возвращает пустую строку. Бот использует `uci show` с последующим парсингом — это корректный обход, прозрачный для пользователя.

**URLTest режим** требует заполненного списка ссылок перед переключением — иначе `podkop` не запустится. Бот предупреждает и предлагает клонировать ссылки из Selector одной кнопкой.

**Single URL режим** — бот удерживает перезапуск `podkop` до получения ссылки, чтобы не уронить туннель на пустом `proxy_string`.

**Active Outbound Probe** использует текущий маршрут секции через Mixed Proxy и не переключает outbound временно. Определение страны через Google / YouTube / Cloudflare носит диагностический характер.

**Mixed Proxy без заданного порта** — если `mixed_proxy_port` не установлен в UCI и включить Mixed Proxy через бота, podkop падал с `jq: invalid JSON`. Исправлено в `v0.14.1`: бот автоматически назначает первый свободный порт начиная с 2080.

---

## 📄 Лицензия

MIT

---

## 🙏 Благодарности

* [itdoginfo/podkop](https://github.com/itdoginfo/podkop) — за сам сервис
* [yandexru45/podkop-evolution](https://github.com/yandexru45/podkop-evolution) — за форк с поддержкой subscription URL и HWID
* [ushan0v/podkop-plus](https://github.com/ushan0v/podkop-plus) — за расширенный вариант podkop с Plus CLI
* [VizzleTF/podkop_autoupdater](https://github.com/VizzleTF/podkop_autoupdater) — за шаблон установщика и идеи DoH-discovery транспорта
* [Davoyan/ipregion_bot](https://github.com/Davoyan/ipregion_bot) — за идеи geo/service-диагностики через прокси
* [vernette/ipregion](https://github.com/vernette/ipregion) — за идеи country/service probes и компактных сетевых проверок

---

## 🇬🇧 Summary

**podkop_bot** is a Telegram bot for remote management of [podkop](https://github.com/itdoginfo/podkop) — a sing-box-based traffic routing service for OpenWrt routers. Supports all three podkop variants: [original](https://github.com/itdoginfo/podkop), [evolution](https://github.com/yandexru45/podkop-evolution), and [plus](https://github.com/ushan0v/podkop-plus) (ushan0v). Provides full control without SSH or LuCI: start/stop/reload, outbound proxy switching with latency display, multi-section support, routing lists editor (with human-readable labels — Service Lists, Domain List URLs, Devices → Tunnel, Devices → Bypass), DNS and YACD settings, subscription traffic/expiry display (Plus), URLTest filters by country/regex (Plus), zapret/byedpi section management (Plus), and GitHub connectivity health check with real latency via WAN and SOCKS.

The bot maintains reachability through a 5-tier fallback transport chain (Podkop SOCKS → Fallback SOCKS list → Custom Proxy → Direct → Emergency IPs with DoH-based self-refresh every 6h from Cloudflare/Google/Quad9) with sticky routing, IPC-based recovery signalling, and automatic return to tier1 within one health interval after podkop recovers. A persistent reply keyboard (`🏠 Menu | 📊 Status`) is available at all times including during watchdog alerts.

Full [changelog](CHANGELOG.md) and [menu structure reference](BOT_STRUCTURE.md) available.

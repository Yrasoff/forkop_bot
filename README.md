# 🤖 podkop_bot v0.14.3

Telegram-бот для удалённого управления [podkop](https://github.com/itdoginfo/podkop) — сервисом маршрутизации трафика для OpenWrt на базе sing-box.

Позволяет управлять службой podkop на роутере и выполнять диагностику прямо из Telegram — без доступа к LuCI и SSH.

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
* Установленный и настроенный [podkop](https://github.com/itdoginfo/podkop) 0.7.x с включённым Mixed Proxy Port (2080)
* Пакеты: `curl`, `jq` (устанавливаются автоматически)
* Токен Telegram-бота (получить у [@BotFather](https://t.me/BotFather))
* TG User ID администратора(-ов) — например через [@Getmyid_Work_Bot](https://t.me/Getmyid_Work_Bot)

---

## ✨ Что умеет бот

### 🛡️ Управление сервисом

* Статус `podkop` и `sing-box` в реальном времени
* Запуск / остановка / перезагрузка `podkop`
* Включение / выключение автозапуска
* Обновление `podkop` до последней версии
* **Обновление самого бота** прямо из меню Info (без SSH)

  * перед обновлением бот показывает доступную версию и краткий блок **What's New**
  * даёт ссылку на changelog
  * **Force Update** — принудительная переустановка текущей версии для применения патчей
* **Перезагрузка роутера** с двойным подтверждением (кнопка + ввод `YES`)

### 🌐 Outbound Selector / URLTest

* Просмотр списка outbound'ов с задержкой и типом протокола
* Переключение активного outbound
* Активный outbound выделен маркером `▶`
* Тест задержки всех outbound'ов одной кнопкой
* Добавление и удаление ссылок (vless://, hy2://, ss://, trojan://, vmess://, tuic://)
* Удаление по `server:port` — надёжно для всех протоколов
* Заголовок карточки отражает режим: **Outbound Selector** или **URLTest Outbounds**
* **Клонирование ссылок из Selector в URLTest** одной кнопкой
* Предупреждение при переключении в URLTest, если список ссылок пуст
* **Single URL Proxy** — отдельный режим для одной ссылки с корректными подсказками

### ⚙️ Настройки секций podkop

* Переключение между секциями (`main`, `antiz` и любыми другими)
* **Корректная работа с несколькими секциями** — данные всегда читаются из активной секции, транспорт бота всегда привязан к первичной proxy-секции
* Тип подключения (`proxy` / `vpn` / `block` / `exclusion`)
* Режим прокси (`selector` / `urltest` / `url` / `outbound`) — переключение через меню
* **Защита при переключении в URL-режим** — бот удерживает reload до получения ссылки, туннель не падает
* **Auto-assign порта Mixed Proxy** при включении — если порт не задан, подбирает свободный (2080, 2081, …)
* URLTest: testing URL, интервал проверки, допуск задержки, список ссылок
* Domain Resolver: включение, тип DNS, сервер — для каждой секции отдельно
* Outbound Interface: привязка секции к конкретному интерфейсу

### 📋 Маршрутизация и списки

* Community lists: включение / выключение по отдельности
* Remote domain / subnet lists: добавление и удаление URL
* Fully Routed IPs: IP/CIDR, которые всегда идут через туннель
* Routing Excluded IPs: IP/CIDR, которые всегда идут напрямую
* Редактор пользовательских доменов и подсетей (постраничный)

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
* **Автодобавление mixed_proxy других секций** как fallback tier'ов — не нужно вручную дублировать порты
* **Admins** — см. раздел ниже

### 👤 Управление администраторами

Список администраторов бота редактируется прямо в Telegram — SSH и UCI не нужны.

Открыть: **Bot Settings → 👤 Admins**

* **Основной admin** (`chat_id`) — отображается с 🔒, удалить нельзя
* **Дополнительные admins** — добавить User ID кнопкой **➕ Add Admin** (вводится числом в чат), удалить с подтверждением
* **Anonymous group admins** — кнопка-переключатель 🟢/🔴: разрешить/запретить анонимным администраторам группы управлять ботом
* **🤖 Bot Info & Invite** — показывает `@username` бота, его ID и версию, плюс пошаговую инструкцию как добавить бота в группу и получить `chat_id`

> После добавления бота в группу достаточно нажать **➕ Add Admin** и ввести `chat_id` группы — бот начнёт принимать команды из неё и слать алерты туда.

### 📊 Диагностика и мониторинг

* **System & Podkop Status**: общая системная карточка — Host, uptime, RAM, CPU, все VPN-интерфейсы, версии, статус sing-box
* **Tunnel Health**: статус `sing-box`, `nftables`, режим, WAN, transport latency по tier'ам

  * два независимых TG health-чека: `TG direct` и `TG tunnel SOCKS5`
  * tier2 SOCKS health при наличии fallback
  * блок **Active outbounds by section** — задержка и доступность Telegram для каждой секции podkop в одном экране
* **Runtime Info**: подключения, трафик, активный outbound, задержка, маршрут бота
* **Diagnostics**: отдельный экран для тяжёлых тестов с подтверждением перед запуском

  * Upstream Health
  * Global Check (`podkop global_check`)
  * Internal Diagnostics
  * Support Bundle
* **Active Outbound Probe**: полная диагностика через **текущий активный outbound**, без переключения selector / URLTest

  * Exit IP + GeoIP (ipapi.co + Cloudflare + Google)
  * YouTube country hint (через sw.js_data)
  * Доступность сервисов: YouTube, Telegram API, ChatGPT, Claude.ai, Gemini, Discord
  * Двухэтапный тест скорости: 32 KB (детект РКН-обрыва после 16 KB) + 1 MB замер
  * Контекстные кнопки по результату: Switch Proxy / Test All / Bot Settings
* **Support Bundle**: одной кнопкой — UCI-конфиг, маршруты, nft, syslog

### 🔔 Watchdog и алерты

* Мониторинг `sing-box` (алерт при остановке и восстановлении)
* Мониторинг SOCKS upstream с гистерезисом
* **Умный алерт смены прокси**: различает ручное переключение (`Proxy manually switched`) и автоматическое URLTest (`Proxy auto-switched`)
* TG connectivity мониторинг (`direct` + `tunnel SOCKS5` + `tier2` раздельно)
* Периодическая проверка задержки всех SOCKS tier'ов
* Alerts при деградации маршрута бота на Direct или Emergency IPs
* Все алерты на английском, читаемые, без лишних технических констант

### 📡 Транспортная цепочка бота

Бот сам работает через многоуровневый fallback при блокировках:

```text
tier1   → Podkop SOCKS5 (основной туннель, primary proxy-секция)
tier2_N → Fallback SOCKS list (socks5:// / socks5h://) + авто-секции с mixed_proxy
tier3   → Custom Proxy
tier4   → Direct
tier5   → Emergency hardcoded Telegram IPs
```

Sticky-routing, Recovery Mode и IPC между watchdog и main loop позволяют боту оставаться доступным даже при проблемах с основным туннелем.

После восстановления `podkop` бот возвращается на `tier1` в течение одного health interval (обычно ≤60 сек).

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
| `BOT_STRUCTURE.md` | [Структура меню](BOT_STRUCTURE.md) — все карточки, строки и кнопки с описанием |
| `CHANGELOG.md` | История изменений (EN) |
| `CHANGELOG_RUS.md` | История изменений (RU) |
| `version.txt` | Актуальная версия для self-update |
| `highlights.txt` | Краткое описание новой версии для карточки обновления |

---

## ⚠️ Известные особенности

**OpenWrt 24.10.x — баг в BusyBox `tr`:**
Символьный класс `[:space:]` обрабатывается некорректно и удаляет букву `e` (`0x65`). Исправлено в `v0.13.90` заменой на явное перечисление символов `\n\r\t `. Затрагивает сборки OpenWrt 24.10.x вне зависимости от архитектуры. Подробнее — в [CHANGELOG.md](CHANGELOG.md#v01390).

**URLTest режим** требует заполненного `urltest_proxy_links` перед переключением — иначе `podkop` не запустится. Бот предупреждает и предлагает клонировать ссылки из Selector одной кнопкой.

**Single URL режим** — бот удерживает перезапуск `podkop` до получения ссылки, чтобы не уронить туннель на пустом `proxy_string`.

**Active Outbound Probe** использует текущий маршрут секции через Mixed Proxy и не переключает outbound временно. Определение страны через Google / YouTube / Cloudflare носит диагностический характер и может отличаться от поведения сервисов, зависящих от аккаунта, cookies, locale или внутренней региональной логики.

**Mixed Proxy без заданного порта** — если `mixed_proxy_port` не установлен в UCI и включить Mixed Proxy через бота, podkop падал с `jq: invalid JSON`. Исправлено в `v0.14.1`: бот автоматически назначает первый свободный порт начиная с 2080.

---

## 📄 Лицензия

MIT

---

## 🙏 Благодарности

* [itdoginfo/podkop](https://github.com/itdoginfo/podkop) — за сам сервис
* [VizzleTF/podkop_autoupdater](https://github.com/VizzleTF/podkop_autoupdater) — за шаблон установщика
* [Davoyan/ipregion_bot](https://github.com/Davoyan/ipregion_bot) — за идеи geo/service-диагностики через прокси
* [vernette/ipregion](https://github.com/vernette/ipregion) — за идеи country/service probes и компактных сетевых проверок

Часть диагностических идей вдохновлена внешними проектами, реализация адаптирована под OpenWrt / BusyBox `ash` и архитектуру `podkop_bot`.

---

## 🇬🇧 Summary

**podkop_bot** is a Telegram bot for remote management of [podkop](https://github.com/itdoginfo/podkop) — a sing-box-based traffic routing service for OpenWrt routers. It provides control over podkop without SSH or LuCI access: start/stop/reload, outbound proxy switching with latency display, correct multi-section support, routing lists editor, DNS and YACD settings, and a multi-tier watchdog that keeps the bot reachable through Telegram even when the main tunnel is down.

The bot operates via a 5-tier fallback transport chain (Podkop SOCKS → Fallback SOCKS list → Custom Proxy → Direct → Emergency IPs) with sticky routing, IPC-based recovery signalling, active outbound diagnostics (geo + service reachability + two-stage speed test), admin management UI, and automatic return to tier1 within one health interval after podkop recovers.

Full [changelog](CHANGELOG.md) and [menu structure reference](BOT_STRUCTURE.md) available.

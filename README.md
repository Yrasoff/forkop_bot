# 🤖 podkop_bot v0.13.98

Telegram-бот для удалённого управления [podkop](https://github.com/itdoginfo/podkop) — сервисом маршрутизации трафика для OpenWrt на базе sing-box.

Позволяет управлять службой podkop на роутере и выполнять диагностику прямо из Telegram — без доступа к LuCI и SSH.

> 📋 История изменений — [CHANGELOG_RUS.md](CHANGELOG_RUS.md)

---

## 🚀 Быстрая установка

```sh
wget -O /tmp/install_podkop_bot.sh https://raw.githubusercontent.com/Medvedolog/podkop_bot/main/install.sh
ash /tmp/install_podkop_bot.sh
````

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

  * перед обновлением бот показывает доступную версию
  * выводит краткий блок **What’s New**
  * даёт ссылку на changelog
* **Перезагрузка роутера** с двойным подтверждением (кнопка + ввод `YES`)

### 🌐 Outbound Selector / URLTest

* Просмотр списка outbound'ов с задержкой и типом протокола
* Переключение активного outbound
* Активный outbound выделен жирным и маркером `▶`
* Тест задержки всех outbound'ов одной кнопкой
* Добавление и удаление ссылок
* Удаление по `server:port` — надёжно для разных протоколов
* Заголовок карточки отражает режим: **Outbound Selector** или **URLTest Outbounds**
* **Клонирование ссылок из Selector в URLTest** одной кнопкой
* Предупреждение при переключении в URLTest, если список ссылок пуст
* **Single URL Proxy** — отдельный режим для одной ссылки с корректными подсказками

### ⚙️ Настройки секций podkop

* Переключение между секциями (`main`, `antiz` и любыми другими)
* **Корректная работа с несколькими секциями** — данные всегда читаются из активной секции, а не из `main`
* Тип подключения (`proxy` / `vpn` / `block` / `exclusion`)
* Режим прокси (`selector` / `urltest` / `url` / `outbound`) — переключение через меню
* **Защита при переключении в URL-режим** — бот удерживает reload до получения ссылки, туннель не падает
* URLTest: testing URL, интервал проверки, допуск задержки, список ссылок
* Domain Resolver: включение, тип DNS, сервер — для каждой секции отдельно
* Mixed Proxy: включение / выключение, порт (с валидацией `1024–65535`)
* Outbound Interface: привязка секции к конкретному интерфейсу

### 📋 Маршрутизация и списки

* Community lists: включение / выключение по отдельности
* Remote domain / subnet lists: добавление и удаление URL
* Fully Routed IPs: IP/CIDR, которые всегда идут через туннель
* Routing Excluded IPs: IP/CIDR, которые всегда идут напрямую (глобальная настройка)
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
* Активный tier выделен жирным и маркером `◀ active`
* Custom Proxy
* Bind Interface
* Тест задержки до Telegram через каждый tier

### 📊 Диагностика и мониторинг

* **Tunnel Health**: статус `sing-box`, `nftables`, режим, WAN, transport latency по tier'ам

  * два независимых TG health-чека: `TG direct` и `TG via Podkop (tier1)`
* **Runtime Info**: подключения, трафик, активный outbound, задержка, маршрут бота
* **Diagnostics**: отдельный экран для тяжёлых тестов с подтверждением перед запуском

  * Upstream Health
  * Global Check
  * Internal Diagnostics
  * Support Bundle
* **Active Outbound Probe**: проверки через **текущий активный outbound**, без переключения selector / URLTest

  * exit IP
  * geo hints
  * Cloudflare / Google / YouTube region hints
  * проверка доступности популярных сервисов через текущий egress
  * лёгкий speed test через active outbound
  * все тесты идут через текущий `mixed_proxy`, без временного переключения на другой proxy
* **Support Bundle**: одной кнопкой собирает архив диагностики

  * UCI-конфиг
  * маршруты
  * `nft`
  * `syslog`

### 🔔 Watchdog и алерты

* Мониторинг `sing-box` (алерт при остановке и восстановлении)
* Мониторинг SOCKS upstream с гистерезисом `2/2`
* **Умный алерт смены прокси**: различает ручное переключение (`Proxy manually switched`) и автоматическое URLTest (`Proxy auto-switched`)
* TG connectivity мониторинг (`direct` + `via SOCKS` раздельно)
* Периодическая проверка задержки всех SOCKS tier'ов
* Все алерты на английском, читаемые, без лишних технических констант

### 📡 Транспортная цепочка бота

Бот сам работает через многоуровневый fallback при блокировках:

```text
tier1   → Podkop SOCKS5 (основной туннель)
tier2_N → Fallback SOCKS list (socks5:// / socks5h://)
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
* несколько `admin_ids` (добавляются через `uci add_list`)
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
├── settings.custom_proxy    — legacy один прокси
├── settings.bind_interface  — привязка к интерфейсу
├── settings.health_interval — интервал watchdog (сек, default 60)
├── settings.alert_notify    — 1/0 алерты
└── settings.startup_notify  — 1/0 уведомление при старте
```

> **Важно:** `admin_ids` добавляются через `uci add_list`, а не через `uci set` — иначе несколько ID не сохранятся корректно.

```sh
uci add_list podkop_bot.settings.admin_ids="123456789"
uci add_list podkop_bot.settings.admin_ids="987654321"
uci commit podkop_bot
```

---

## ⚠️ Известные особенности

**OpenWrt 24.10.x — баг в BusyBox `tr`:**
Символьный класс `[:space:]` обрабатывается некорректно и удаляет букву `e` (`0x65`). Исправлено в `v0.13.90` заменой на явное перечисление символов `\n\r\t `. Затрагивает сборки OpenWrt 24.10.x вне зависимости от архитектуры. Подробнее — в [CHANGELOG.md](CHANGELOG.md#v01390).

**URLTest режим** требует заполненного `urltest_proxy_links` перед переключением — иначе `podkop` не запустится. Бот предупреждает и предлагает клонировать ссылки из Selector одной кнопкой.

**Single URL режим** — бот удерживает перезапуск `podkop` до получения ссылки, чтобы не уронить туннель на пустом `proxy_string`.

**Active Outbound Probe** использует текущий маршрут секции через Mixed Proxy и не переключает outbound временно. Определение страны через Google / YouTube / Cloudflare носит диагностический характер и может отличаться от поведения сервисов, зависящих от аккаунта, cookies, locale или внутренней региональной логики.

---

## 📄 Лицензия

MIT

---

## 🙏 Благодарности

* [itdoginfo/podkop](https://github.com/itdoginfo/podkop) — за сам сервис
* [VizzleTF/podkop_autoupdater](https://github.com/VizzleTF/podkop_autoupdater) — за шаблон установщика
* [Davoyan/ipregion_bot](https://github.com/Davoyan/ipregion_bot) — за идеи geo/service-диагностики через прокси
* [vernette/ipregion](https://github.com/vernette/ipregion) — за идеи country/service probes и компактных сетевых проверок

Часть диагностических идей была вдохновлена внешними проектами, но реализация адаптирована под OpenWrt / BusyBox `ash` и архитектуру самого `podkop_bot`.

---

## 🇬🇧 Summary

**podkop_bot** is a Telegram bot for remote management of [podkop](https://github.com/itdoginfo/podkop) — a sing-box-based traffic routing service for OpenWrt routers. It provides control over podkop without SSH or LuCI access: start/stop/reload, outbound proxy switching with latency display, correct multi-section support, routing lists editor, DNS and YACD settings, and a multi-tier watchdog that keeps the bot reachable through Telegram even when the main tunnel is down. The bot operates via a 5-tier fallback transport chain (Podkop SOCKS → Fallback SOCKS list → Custom Proxy → Direct → Emergency IPs) with sticky routing, IPC-based recovery signalling, active outbound diagnostics, and automatic return to tier1 within one health interval after podkop recovers. Full [changelog](CHANGELOG.md) available.

```

Если нужно, я могу сразу сделать ещё и отдельный блок для `CHANGELOG_RUS.md` в том же стиле.
```

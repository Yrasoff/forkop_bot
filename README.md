# 🤖 podkop_bot v0.13.77

Telegram-бот для удалённого управления [podkop](https://github.com/itdoginfo/podkop) — сервисом маршрутизации трафика для OpenWrt на базе sing-box.

Позволяет управлять службой podkop на роутере и осуществлять мониторинг прямо из Telegram — без доступа к LuCI и SSH.

---

## 🚀 Быстрая установка

```sh
wget -O /tmp/install_podkop_bot.sh https://raw.githubusercontent.com/Medvedolog/podkop_bot/main/install.sh
ash /tmp/install_podkop_bot.sh
```

---

## 📋 Требования

- OpenWrt 24.x / 25.x или ImmortalWrt
- Установленный и настроенный [podkop](https://github.com/itdoginfo/podkop) 0.7.X с включенным Mixed Proxy Port (2080)
- Пакеты: `curl`, `jq` (устанавливаются автоматически)
- Токен Telegram-бота (получить у [@BotFather](https://t.me/BotFather))
- TG User ID админа(-ов) - @Getmyid_Work_Bot

---

## ✨ Что умеет бот

### 🛡️ Управление сервисом
- Статус podkop и sing-box в реальном времени
- Запуск / остановка / перезагрузка podkop
- Включение/выключение автозапуска
- Обновление podkop до последней версии

### 🌐 Outbound Selector
- Просмотр списка outbound'ов с задержкой и типом протокола
- Переключение активного outbound (vless, hy2, hysteria2, ss, trojan, vmess, tuic)
- Тест задержки всех outbound'ов одной кнопкой
- Добавление и удаление ссылок на outbound'ы
- URLTest, URL Links и Outbound режимы работы

### ⚙️ Настройки секций podkop
- Переключение между секциями
- Тип подключения (proxy / vpn / block / exclusion)
- Режим прокси (selector / urltest / url / outbound)
- URLTest: testing URL, интервал проверки, допуск задержки, список ссылок
- Domain Resolver: включение, тип DNS, сервер — для каждой секции отдельно
- Mixed Proxy: включение/выключение, порт (с валидацией 1024–65535)
- Outbound Interface: привязка секции к конкретному интерфейсу

### 📋 Маршрутизация и списки
- Community lists: включение/выключение по отдельности
- Remote domain / subnet lists: добавление и удаление URL
- Fully Routed IPs и Routing Excluded IPs: добавление/удаление с валидацией CIDR
- Редактор пользовательских доменов и подсетей (постраничный)

### 🌍 DNS и YACD
- Тип DNS (udp / doh / dot), сервер, bootstrap DNS
- YACD: включение, WAN-доступ, управление секретным ключом

### 🔧 Настройки Bad WAN
- Включение мониторинга
- Список отслеживаемых интерфейсов
- Задержка перезагрузки

### 🤖 Управление транспортом бота
- **Transport Policy**: auto / socks / direct — с описанием рисков и подтверждением
- **Fallback SOCKS** (tier2_N): добавление, удаление, тест доступности всех tier'ов
- Custom Proxy, Bind Interface
- Тест задержки до Telegram через каждый tier

### 📊 Диагностика и мониторинг
- **Tunnel Health**: статус sing-box, nftables, режим, WAN, transport latency по тирам
- **Runtime Info**: подключения, трафик, активный outbound, задержка
- **Upstream Health**: полный тест всех outbound'ов с задержками
- **Global Check** и Internal Diagnostics
- **Support Bundle**: одна кнопка — архив диагностики (UCI конфиг, маршруты, nft, syslog)

### 🔔 Watchdog и алерты
- Мониторинг sing-box (алерт при остановке и восстановлении с контекстом)
- Мониторинг SOCKS upstream с гистерезисом 2/2
- Алерт при смене активного outbound (URLTest/Selector автопереключение)
- TG connectivity мониторинг
- Периодическая проверка задержки всех SOCKS tier'ов (~каждые 5 мин)
- Все алерты содержат имя роутера, активный outbound, маршрут бота, доступность fallback

### 📡 Транспортная цепочка бота
Бот сам работает через многоуровневый fallback при блокировках:
```
tier1  → Podkop SOCKS5 (основной туннель)
tier2_N → Fallback SOCKS list (socks5:// / socks5h://)
tier3  → Custom Proxy
tier4  → Direct
tier5  → Emergency hardcoded Telegram IPs
```
Sticky-роутинг, Recovery Mode, IPC между watchdog и main loop.

---

## 👥 Несколько роутеров и администраторов

Поддерживается схема с несколькими ботами в одном Telegram supergroup:
- Каждый роутер — отдельный bot token
- Несколько `admin_ids` через пробел в UCI
- Все алерты содержат `[hostname]` префикс для идентификации роутера
- Anonymous admins в группах через `ALLOW_ANON_ADMINS`

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

```
/etc/config/podkop_bot
├── settings.bot_token       — токен бота
├── settings.chat_id         — основной chat_id (куда слать алерты)
├── settings.admin_ids       — список user_id через пробел
├── settings.transport       — auto / socks / direct
├── settings.fallback_socks  — list socks5h://... 
├── settings.custom_proxy    — legacy один прокси
├── settings.bind_interface  — привязка к интерфейсу
├── settings.health_interval — интервал watchdog (сек, default 60)
├── settings.alert_notify    — 1/0 алерты
└── settings.startup_notify  — 1/0 уведомление при старте
```

---

## 📄 Лицензия

MIT

---

## 🙏 Благодарности и вдохновение

- [itdoginfo/podkop](https://github.com/itdoginfo/podkop) — за сам сервис
- [VizzleTF/podkop_autoupdater](https://github.com/VizzleTF/podkop_autoupdater) — за шаблон установщика и код Podkop_autoupdater

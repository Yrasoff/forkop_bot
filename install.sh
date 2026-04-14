#!/bin/ash

# Installer script for podkop_bot
# Downloads, configures, and sets up podkop_bot on OpenWrt
# Supports: OpenWrt 23.x / 24.x (opkg) and OpenWrt 25.x+ (apk)
# Based on installer pattern from https://github.com/VizzleTF/podkop_autoupdater

# ── Constants ──────────────────────────────────────────────────────────────────
BOT_URL="https://raw.githubusercontent.com/Medvedolog/podkop_bot/main/podkop_bot.sh"
BOT_PATH="/usr/bin/podkop_bot"
INIT_PATH="/etc/init.d/podkop_bot"
INIT_URL="https://raw.githubusercontent.com/Medvedolog/podkop_bot/main/podkop_bot_init"
UCI_PKG="podkop_bot"
UCI_SEC="settings"
OS_RELEASE_FILE="/etc/os-release"
TOKEN_DISPLAY_LENGTH=10

# ── Helpers ────────────────────────────────────────────────────────────────────
exit_with_error() {
    echo ""
    echo "Ошибка: $1"
    exit 1
}

info() { echo "  $1"; }
ok()   { echo "OK $1"; }
warn() { echo "!! $1"; }

download_file() {
    local url="$1" dest="$2"
    wget -q -O "$dest" "$url" 2>/dev/null \
        || curl -s -o "$dest" "$url" 2>/dev/null \
        || exit_with_error "Не удалось скачать $url. Проверьте интернет."
}

uci_set() { uci set    "${UCI_PKG}.${UCI_SEC}.${1}=${2}" 2>/dev/null; }
uci_get() { uci -q get "${UCI_PKG}.${UCI_SEC}.${1}" 2>/dev/null; }

# ── Check OS ───────────────────────────────────────────────────────────────────
if ! grep -qE "OpenWrt|immortalwrt|ImmortalWrt" "$OS_RELEASE_FILE" 2>/dev/null; then
    exit_with_error "Скрипт предназначен для OpenWrt / ImmortalWrt."
fi

echo ""
echo "podkop_bot -- установщик"
echo "========================"
echo ""

# ── Detect package manager (opkg vs apk) ──────────────────────────────────────
# OpenWrt 23.x / 24.x uses opkg.
# OpenWrt 25.x+ migrated to apk (Alpine Package Keeper).
# Detection priority:
#   1. Binary presence (most reliable — works even if PATH is non-standard)
#   2. VERSION_ID from /etc/os-release (fallback)
PKG_MANAGER=""
if command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
elif command -v opkg >/dev/null 2>&1; then
    PKG_MANAGER="opkg"
else
    # Neither binary in PATH — parse VERSION_ID
    # VERSION_ID format: "24.10.1" or "25.xx.x" or "SNAPSHOT"
    _ver=$(grep "^VERSION_ID=" "$OS_RELEASE_FILE" 2>/dev/null | cut -d'"' -f2)
    _major=$(echo "$_ver" | cut -d'.' -f1)
    if echo "$_major" | grep -qE '^[0-9]+$' && [ "$_major" -ge 25 ]; then
        PKG_MANAGER="apk"
    else
        PKG_MANAGER="opkg"
    fi
    unset _ver _major
fi

info "Версия OpenWrt: $(grep '^VERSION_ID=' "$OS_RELEASE_FILE" 2>/dev/null | cut -d'"' -f2 || echo 'unknown')"
info "Пакетный менеджер: ${PKG_MANAGER}"
echo ""

# ── Package manager wrappers ───────────────────────────────────────────────────
# All package operations go through these wrappers so the rest of the script
# is identical regardless of opkg vs apk.

pkg_update() {
    case "$PKG_MANAGER" in
        apk)  apk update >/dev/null 2>&1 ;;
        opkg) opkg update >/dev/null 2>&1 ;;
    esac
}

pkg_is_installed() {
    # Returns 0 if package is installed, 1 otherwise
    local pkg="$1"
    case "$PKG_MANAGER" in
        apk)
            # apk info exits 0 if package is installed
            apk info "$pkg" >/dev/null 2>&1
            ;;
        opkg)
            opkg list-installed 2>/dev/null | grep -q "^${pkg} "
            ;;
    esac
}

pkg_install() {
    local pkg="$1"
    case "$PKG_MANAGER" in
        apk)  apk add "$pkg" >/dev/null 2>&1 ;;
        opkg) opkg install "$pkg" >/dev/null 2>&1 ;;
    esac
}

# ── Install dependencies ───────────────────────────────────────────────────────
info "Обновление индекса пакетов..."
pkg_update

info "Установка зависимостей (curl, jq)..."
for pkg in curl jq; do
    if pkg_is_installed "$pkg"; then
        info "  $pkg — уже установлен"
    else
        info "  Установка $pkg..."
        pkg_install "$pkg" || exit_with_error "Не удалось установить $pkg."
        ok "$pkg установлен."
    fi
done
echo ""

# ── Check existing installation ────────────────────────────────────────────────
EXISTING_TOKEN=$(uci_get bot_token)
EXISTING_CHAT=$(uci_get chat_id)

if [ -f "$BOT_PATH" ] && [ -n "$EXISTING_TOKEN" ] && [ -n "$EXISTING_CHAT" ]; then
    echo "Обнаружена существующая установка:"
    echo "  Токен:   ${EXISTING_TOKEN:0:$TOKEN_DISPLAY_LENGTH}..."
    echo "  Chat ID: $EXISTING_CHAT"
    echo ""
    echo "Выберите действие:"
    echo "  1) Обновить скрипт, сохранить конфиг  (по умолчанию)"
    echo "  2) Переустановить с новыми настройками"
    echo "  3) Выйти без изменений"
    printf "Введите 1, 2 или 3: "
    read -r CHOICE
    echo ""
    case "$CHOICE" in
        2)
            info "Переустановка с новыми настройками..."
            ;;
        3)
            ok "Установка пропущена. Текущий конфиг сохранён."
            exit 0
            ;;
        1|*)
            info "Обновление скрипта без изменения конфига..."
            download_file "$BOT_URL" "$BOT_PATH"
            chmod +x "$BOT_PATH"
            ok "Скрипт обновлён: $BOT_PATH"
            echo ""
            if [ -f "$INIT_PATH" ] && "$INIT_PATH" status >/dev/null 2>&1; then
                "$INIT_PATH" restart >/dev/null 2>&1 && ok "Сервис перезапущен."
            fi
            echo "Установка завершена!"
            exit 0
            ;;
    esac
fi

# ── Download bot script ────────────────────────────────────────────────────────
info "Скачивание podkop_bot..."
download_file "$BOT_URL" "$BOT_PATH"
chmod +x "$BOT_PATH"
ok "Скачан: $BOT_PATH"
echo ""

# ── Configure bot token ────────────────────────────────────────────────────────
echo "-- Настройка бота --"
echo ""
printf "Введите токен Telegram-бота (от @BotFather):\n> "
read -r BOT_TOKEN
[ -z "$BOT_TOKEN" ] && exit_with_error "Токен не может быть пустым."

info "Проверка токена через Telegram API..."
TG_CHECK=$(curl -s --connect-timeout 8 \
    "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null)
if ! echo "$TG_CHECK" | grep -q '"ok":true'; then
    warn "Не удалось подтвердить токен. Убедитесь что токен верный и есть интернет."
    printf "Продолжить установку с этим токеном? (y/N): "
    read -r CONT
    [ "$CONT" != "y" ] && [ "$CONT" != "Y" ] && exit_with_error "Установка прервана."
else
    BOT_NAME=$(echo "$TG_CHECK" | jq -r '.result.username // "unknown"' 2>/dev/null)
    ok "Токен валиден. Бот: @${BOT_NAME}"
fi
echo ""

# ── Configure chat_id ──────────────────────────────────────────────────────────
printf "Введите Chat ID или User ID для алертов\n(личный чат, группа или supergroup):\n> "
read -r CHAT_ID
[ -z "$CHAT_ID" ] && exit_with_error "Chat ID не может быть пустым."

# ── Optional: additional admin IDs ────────────────────────────────────────────
echo ""
printf "Дополнительные admin User ID (через пробел, Enter чтобы пропустить):\n> "
read -r ADMIN_IDS

# ── Optional: allow anonymous group admins ─────────────────────────────────────
echo ""
printf "Разрешить anonymous admins в группах? (Y/n): "
read -r ANON_ADMINS
ANON_ADMINS_VAL=1
[ "$ANON_ADMINS" = "n" ] || [ "$ANON_ADMINS" = "N" ] && ANON_ADMINS_VAL=0

# ── Write UCI config ───────────────────────────────────────────────────────────
info "Запись конфига в UCI..."
uci -q delete "${UCI_PKG}.${UCI_SEC}" 2>/dev/null
uci set "${UCI_PKG}.${UCI_SEC}=settings"
uci_set "bot_token"              "$BOT_TOKEN"
uci_set "chat_id"                "$CHAT_ID"
uci_set "allow_anonymous_admins" "$ANON_ADMINS_VAL"
[ -n "$ADMIN_IDS" ] && uci_set "admin_ids" "$ADMIN_IDS"
uci_set "transport"              "auto"
uci_set "health_interval"        "60"
uci_set "alert_notify"           "1"
uci_set "startup_notify"         "1"
uci commit "$UCI_PKG" || exit_with_error "uci commit failed."
ok "UCI конфиг записан (/etc/config/${UCI_PKG})."
echo ""

# ── Init script ────────────────────────────────────────────────────────────────
echo "-- Автозапуск --"
echo ""
printf "Установить автозапуск через init.d? (Y/n): "
read -r SETUP_INIT

if [ "$SETUP_INIT" != "n" ] && [ "$SETUP_INIT" != "N" ]; then
    # Try repo init script first; generate locally if not available
    INIT_OK=0
    if wget -q --spider "$INIT_URL" >/dev/null 2>&1 || \
       curl -sf --head "$INIT_URL" >/dev/null 2>&1; then
        download_file "$INIT_URL" "$INIT_PATH"
        INIT_OK=1
    fi
    if [ "$INIT_OK" = "0" ]; then
        # procd-based init script — works on OpenWrt 23.x/24.x/25.x+
        cat > "$INIT_PATH" << 'INITEOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
PROG=/usr/bin/podkop_bot

start_service() {
    procd_open_instance
    procd_set_param command "$PROG"
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 0
    procd_set_param stderr 0
    procd_close_instance
}
INITEOF
    fi
    chmod +x "$INIT_PATH"
    "$INIT_PATH" enable >/dev/null 2>&1
    ok "Автозапуск включён (/etc/init.d/podkop_bot)."
else
    info "Автозапуск пропущен. Запустить вручную: $BOT_PATH &"
fi
echo ""

# ── Start bot ──────────────────────────────────────────────────────────────────
printf "Запустить бота сейчас? (Y/n): "
read -r START_NOW
echo ""

if [ "$START_NOW" != "n" ] && [ "$START_NOW" != "N" ]; then
    if [ -f "$INIT_PATH" ]; then
        "$INIT_PATH" start >/dev/null 2>&1
        sleep 2
        if "$INIT_PATH" status >/dev/null 2>&1; then
            ok "Бот запущен через init.d."
        else
            warn "init.d статус неизвестен. Проверьте: logread | grep podkop-bot"
            "$BOT_PATH" &
            ok "Бот запущен напрямую (PID: $!)."
        fi
    else
        "$BOT_PATH" &
        ok "Бот запущен (PID: $!)."
    fi
else
    info "Бот не запущен. Запустить: $BOT_PATH &"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "=========================="
echo "   Установка завершена!"
echo "=========================="
echo ""
echo "  Скрипт:    $BOT_PATH"
echo "  Конфиг:    /etc/config/${UCI_PKG}"
echo "  Логи:      logread | grep podkop-bot"
echo "  Пакеты:    ${PKG_MANAGER}"
echo ""
echo "Полезные команды:"
echo "  /etc/init.d/podkop_bot start|stop|restart|status"
echo "  logread -f | grep podkop-bot"
echo ""
echo "Управление UCI:"
echo "  uci show ${UCI_PKG}"
echo "  uci set ${UCI_PKG}.${UCI_SEC}.health_interval=60"
echo "  uci set ${UCI_PKG}.${UCI_SEC}.alert_notify=0"
echo "  uci commit ${UCI_PKG}"
echo ""
echo "GitHub: https://github.com/Medvedolog/podkop_bot"

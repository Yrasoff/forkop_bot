#!/bin/ash

# Installer for podkop_bot — Telegram remote management bot for podkop/sing-box on OpenWrt
# Supports: OpenWrt 23.05 / 24.10 (opkg) and OpenWrt 25.x+ (apk)
# Based on installer pattern from https://github.com/VizzleTF/podkop_autoupdater
#
# CORRECT install command:
#   wget -O /tmp/install_podkop_bot.sh \
#     https://raw.githubusercontent.com/Medvedolog/podkop_bot/main/install.sh
#   ash /tmp/install_podkop_bot.sh

# ── Self-check: detect accidental HTML download (wrong GitHub URL) ─────────────
# Correct:  https://raw.githubusercontent.com/...
# Wrong:    https://github.com/.../blob/main/...  -- downloads HTML page
# Check only the first line: HTML starts with <!DOCTYPE or <html, shell starts with #!
_first_line=$(head -1 "$0" 2>/dev/null)
case "$_first_line" in
    '<!DOCTYPE'*|'<html'*)
        echo ""
        echo "ERROR: Downloaded HTML page instead of shell script."
        echo "Use the raw URL:"
        echo ""
        echo "  wget -O /tmp/install_podkop_bot.sh \\"
        echo "    https://raw.githubusercontent.com/Medvedolog/podkop_bot/main/install.sh"
        echo "  ash /tmp/install_podkop_bot.sh"
        echo ""
        exit 1
        ;;
esac
unset _first_line

# ── Constants ──────────────────────────────────────────────────────────────────
BOT_URL="https://raw.githubusercontent.com/Medvedolog/podkop_bot/main/podkop_bot.sh"
VERSION_URL="https://raw.githubusercontent.com/Medvedolog/podkop_bot/main/version.txt"
BOT_PATH="/usr/bin/podkop_bot"
INIT_PATH="/etc/init.d/podkop_bot"
INIT_URL="https://raw.githubusercontent.com/Medvedolog/podkop_bot/main/podkop_bot_init"
UCI_PKG="podkop_bot"
UCI_SEC="settings"
OS_RELEASE_FILE="/etc/os-release"
TOKEN_DISPLAY_LENGTH=10

# ── Helpers ────────────────────────────────────────────────────────────────────
die()  { echo ""; echo "ERROR: $1"; exit 1; }
info() { echo "  $1"; }
ok()   { echo "[OK] $1"; }
warn() { echo "[!!] $1"; }

download_file() {
    local url="$1" dest="$2"
    wget -q -O "$dest" "$url" 2>/dev/null \
        || curl -s -o "$dest" "$url" 2>/dev/null \
        || die "Failed to download $url — check internet connection."
}

uci_get() { uci -q get "${UCI_PKG}.${UCI_SEC}.${1}" 2>/dev/null; }

# ── Check OS ───────────────────────────────────────────────────────────────────
if ! grep -qE "OpenWrt|immortalwrt|ImmortalWrt" "$OS_RELEASE_FILE" 2>/dev/null; then
    die "This script is designed for OpenWrt / ImmortalWrt only."
fi

echo ""
echo "==========================================="
echo "  podkop_bot installer"
echo "==========================================="
echo ""

# ── Detect package manager (opkg vs apk) ──────────────────────────────────────
# OpenWrt 23.05 / 24.10  → opkg
# OpenWrt 25.x+          → apk (Alpine Package Keeper)
#
# Detection order:
#   1. Binary in PATH  — most reliable
#   2. VERSION_ID in /etc/os-release — fallback when binary not yet in PATH
PKG_MANAGER=""
if command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
elif command -v opkg >/dev/null 2>&1; then
    PKG_MANAGER="opkg"
else
    _ver=$(grep "^VERSION_ID=" "$OS_RELEASE_FILE" 2>/dev/null | cut -d'"' -f2)
    _major=$(echo "$_ver" | cut -d'.' -f1)
    if echo "$_major" | grep -qE '^[0-9]+$' && [ "$_major" -ge 25 ] 2>/dev/null; then
        PKG_MANAGER="apk"
    else
        PKG_MANAGER="opkg"
    fi
    unset _ver _major
fi

OWRT_VERSION=$(grep '^VERSION_ID=' "$OS_RELEASE_FILE" 2>/dev/null | cut -d'"' -f2)
info "OpenWrt version : ${OWRT_VERSION:-unknown}"
info "Package manager : ${PKG_MANAGER}"
echo ""

# ── Package manager wrappers ───────────────────────────────────────────────────
# All install operations use these wrappers — rest of the script is PM-agnostic.

pkg_update() {
    case "$PKG_MANAGER" in
        apk)  apk update >/dev/null 2>&1 ;;
        opkg) opkg update >/dev/null 2>&1 ;;
    esac
}

pkg_is_installed() {
    local pkg="$1"
    case "$PKG_MANAGER" in
        apk)  apk info "$pkg" >/dev/null 2>&1 ;;
        opkg) opkg list-installed 2>/dev/null | grep -q "^${pkg} " ;;
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
info "Updating package index..."
pkg_update

info "Installing dependencies: curl, jq"
for pkg in curl jq; do
    if pkg_is_installed "$pkg"; then
        info "  $pkg — already installed"
    else
        info "  Installing $pkg..."
        pkg_install "$pkg" || die "Failed to install $pkg."
        ok "$pkg installed."
    fi
done
echo ""

# ── Check existing installation ────────────────────────────────────────────────
EXISTING_TOKEN=$(uci_get bot_token)
EXISTING_CHAT=$(uci_get chat_id)

if [ -f "$BOT_PATH" ] && [ -n "$EXISTING_TOKEN" ] && [ -n "$EXISTING_CHAT" ]; then
    TOKEN_SHORT=$(printf '%s' "$EXISTING_TOKEN" | cut -c1-${TOKEN_DISPLAY_LENGTH})
    # Read installed version from BOT_VERSION= line in the script
    INSTALLED_VER=$(grep '^BOT_VERSION=' "$BOT_PATH" 2>/dev/null | cut -d'"' -f2)
    [ -z "$INSTALLED_VER" ] && INSTALLED_VER="unknown"

    echo "Existing installation detected:"
    echo "  Token    : ${TOKEN_SHORT}..."
    echo "  Chat ID  : $EXISTING_CHAT"
    echo "  Version  : ${INSTALLED_VER}"
    echo ""
    echo "Choose an option:"
    echo "  1) Update script from GitHub, keep config  [default]"
    echo "  2) Reinstall with new settings"
    echo "  3) Exit without changes"
    printf "Enter 1, 2 or 3: "
    read -r CHOICE
    echo ""
    case "$CHOICE" in
        2)
            info "Reinstalling with new settings..."
            ;;
        3)
            ok "Skipped. Existing config preserved."
            exit 0
            ;;
        1|*)
            # Fetch remote version from version.txt — lightweight (~10 bytes vs ~200KB)
            info "Fetching latest version info from GitHub..."
            REMOTE_VER=$(wget -q -O - "$VERSION_URL" 2>/dev/null | tr -d '[:space:]')
            [ -z "$REMOTE_VER" ] && \
                REMOTE_VER=$(curl -s "$VERSION_URL" 2>/dev/null | tr -d '[:space:]')
            [ -z "$REMOTE_VER" ] && REMOTE_VER="unknown"

            echo ""
            echo "  Installed : v${INSTALLED_VER}"
            echo "  Available : v${REMOTE_VER}"
            echo ""

            if [ "$INSTALLED_VER" = "$REMOTE_VER" ] && [ "$REMOTE_VER" != "unknown" ]; then
                echo "Already up to date."
                printf "Update anyway? (y/N): "
                read -r FORCE_UPDATE
                [ "$FORCE_UPDATE" != "y" ] && [ "$FORCE_UPDATE" != "Y" ] && {
                    ok "No changes made."
                    exit 0
                }
            else
                printf "Update v${INSTALLED_VER} -> v${REMOTE_VER}? (Y/n): "
                read -r CONFIRM_UPDATE
                [ "$CONFIRM_UPDATE" = "n" ] || [ "$CONFIRM_UPDATE" = "N" ] && {
                    ok "Update cancelled. No changes made."
                    exit 0
                }
            fi

            # Stop service before replacing binary
            if [ -f "$INIT_PATH" ] && "$INIT_PATH" status >/dev/null 2>&1; then
                info "Stopping service..."
                "$INIT_PATH" stop >/dev/null 2>&1
                sleep 1
            fi

            info "Downloading v${REMOTE_VER}..."
            download_file "$BOT_URL" "$BOT_PATH"
            chmod +x "$BOT_PATH"
            ok "Updated to v${REMOTE_VER}: $BOT_PATH"
            echo ""

            # Restart service if init.d script exists
            if [ -f "$INIT_PATH" ]; then
                "$INIT_PATH" start >/dev/null 2>&1
                sleep 2
                if "$INIT_PATH" status >/dev/null 2>&1; then
                    ok "Service restarted."
                else
                    warn "Service did not start — check: logread | grep podkop-bot"
                fi
            else
                info "No init.d script found. Start manually: $BOT_PATH &"
            fi
            echo "Done."
            exit 0
            ;;
    esac
fi

# ── Download bot script ────────────────────────────────────────────────────────
info "Downloading podkop_bot..."
download_file "$BOT_URL" "$BOT_PATH"
chmod +x "$BOT_PATH"
ok "Downloaded: $BOT_PATH"
echo ""

# ── Bot token ─────────────────────────────────────────────────────────────────
echo "-------------------------------------------"
echo "  Bot configuration"
echo "-------------------------------------------"
echo ""
printf "Telegram bot token (from @BotFather):\n> "
read -r BOT_TOKEN
[ -z "$BOT_TOKEN" ] && die "Bot token cannot be empty."

info "Verifying token with Telegram API..."
TG_CHECK=$(curl -s --connect-timeout 8 \
    "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null)
if ! echo "$TG_CHECK" | grep -q '"ok":true'; then
    warn "Could not verify token. Check the token and internet connection."
    printf "Continue with this token anyway? (y/N): "
    read -r CONT
    [ "$CONT" != "y" ] && [ "$CONT" != "Y" ] && die "Installation aborted."
else
    BOT_NAME=$(echo "$TG_CHECK" | jq -r '.result.username // "unknown"' 2>/dev/null)
    ok "Token valid. Bot: @${BOT_NAME}"
fi
echo ""

# ── Chat ID ───────────────────────────────────────────────────────────────────
printf "Chat ID or User ID for alerts\n(private chat, group, or supergroup):\n> "
read -r CHAT_ID
[ -z "$CHAT_ID" ] && die "Chat ID cannot be empty."

# ── Additional admin IDs (optional) ───────────────────────────────────────────
echo ""
printf "Additional admin User IDs, space-separated (Enter to skip):\n> "
read -r ADMIN_IDS

# ── Anonymous group admins (optional) ─────────────────────────────────────────
echo ""
printf "Allow anonymous group admins? (Y/n): "
read -r ANON_ADMINS
ANON_ADMINS_VAL=1
[ "$ANON_ADMINS" = "n" ] || [ "$ANON_ADMINS" = "N" ] && ANON_ADMINS_VAL=0

# ── Write UCI config ───────────────────────────────────────────────────────────
info "Writing UCI config..."

# Ensure config file exists before uci operations (fresh system)
[ -f "/etc/config/${UCI_PKG}" ] || touch "/etc/config/${UCI_PKG}" \
    || die "Cannot create /etc/config/${UCI_PKG} — check filesystem."

uci -q delete "${UCI_PKG}.${UCI_SEC}" 2>/dev/null
uci set "${UCI_PKG}.${UCI_SEC}=settings" \
    || die "uci set failed — check /etc/config/ permissions."

uci set "${UCI_PKG}.${UCI_SEC}.bot_token=${BOT_TOKEN}"
uci set "${UCI_PKG}.${UCI_SEC}.chat_id=${CHAT_ID}"
uci set "${UCI_PKG}.${UCI_SEC}.allow_anonymous_admins=${ANON_ADMINS_VAL}"
[ -n "$ADMIN_IDS" ] && uci set "${UCI_PKG}.${UCI_SEC}.admin_ids=${ADMIN_IDS}"
uci set "${UCI_PKG}.${UCI_SEC}.transport=auto"
uci set "${UCI_PKG}.${UCI_SEC}.health_interval=60"
uci set "${UCI_PKG}.${UCI_SEC}.alert_notify=1"
uci set "${UCI_PKG}.${UCI_SEC}.startup_notify=1"

uci commit "$UCI_PKG" || die "uci commit failed."
ok "Config written to /etc/config/${UCI_PKG}"
echo ""

# ── Init script / autostart ────────────────────────────────────────────────────
echo "-------------------------------------------"
echo "  Autostart"
echo "-------------------------------------------"
echo ""
printf "Set up autostart via init.d? (Y/n): "
read -r SETUP_INIT

if [ "$SETUP_INIT" != "n" ] && [ "$SETUP_INIT" != "N" ]; then
    # Try to download init script from repo; generate locally as fallback
    INIT_OK=0
    if wget -q --spider "$INIT_URL" >/dev/null 2>&1 \
    || curl -sf --head "$INIT_URL" >/dev/null 2>&1; then
        download_file "$INIT_URL" "$INIT_PATH"
        INIT_OK=1
    fi
    if [ "$INIT_OK" = "0" ]; then
        # Generate procd init script — compatible with OpenWrt 23.05 / 24.10 / 25.x+
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
    ok "Autostart enabled: /etc/init.d/podkop_bot"
else
    info "Autostart skipped. Run manually: $BOT_PATH &"
fi
echo ""

# ── Start now ─────────────────────────────────────────────────────────────────
printf "Start the bot now? (Y/n): "
read -r START_NOW
echo ""

if [ "$START_NOW" != "n" ] && [ "$START_NOW" != "N" ]; then
    if [ -f "$INIT_PATH" ]; then
        "$INIT_PATH" start >/dev/null 2>&1
        sleep 2
        if "$INIT_PATH" status >/dev/null 2>&1; then
            ok "Bot started via init.d."
        else
            warn "init.d status unknown — starting directly..."
            "$BOT_PATH" &
            ok "Bot started (PID: $!)."
        fi
    else
        "$BOT_PATH" &
        ok "Bot started (PID: $!)."
    fi
else
    info "Bot not started. Run: $BOT_PATH &"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "==========================================="
echo "  Installation complete!"
echo "==========================================="
echo ""
echo "  Script  : $BOT_PATH"
echo "  Config  : /etc/config/${UCI_PKG}"
echo "  Logs    : logread | grep podkop-bot"
echo "  Pkg mgr : ${PKG_MANAGER}"
echo ""
echo "Service commands:"
echo "  /etc/init.d/podkop_bot start|stop|restart|status"
echo "  logread -f | grep podkop-bot"
echo ""
echo "UCI config:"
echo "  uci show ${UCI_PKG}"
echo "  uci set ${UCI_PKG}.${UCI_SEC}.health_interval=60"
echo "  uci set ${UCI_PKG}.${UCI_SEC}.alert_notify=0"
echo "  uci commit ${UCI_PKG}"
echo ""
echo "GitHub: https://github.com/Medvedolog/podkop_bot"

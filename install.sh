#!/bin/bash
set -e

# =====================================================================
# 🎬 VNET MOVIES - UNIVERSAL DEPLOYMENT TOOL  (v2)
#   App  : stream_bot.py  (FastAPI + Pyrogram + TeleBot)
#   View : templates/player.html
#   Web  : Nginx (HTTPS :8443, Cloudflare supported) -> 127.0.0.1:8080
# =====================================================================
SERVICE_NAME="vnet_movies"
APP_PORT="8080"          # uvicorn (127.0.0.1 only)
NGINX_PORT="8443"        # Public HTTPS port (Cloudflare supported)

GITHUB_REPO="VihanNethmira/vnetmovies"

WORK_DIR="/root/VNET_Movies"
SUBS_DIR="$WORK_DIR/subs"
TEMPLATE_DIR="$WORK_DIR/templates"
ENV_FILE="$WORK_DIR/.env"

# මේ script එක තියෙන folder එක (stream_bot.py + player.html මෙතන තියෙනවා නම් ඒවා පාවිච්චි කරනවා)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────────────────────────
# HELPER FUNCTIONS
# ─────────────────────────────────────────────
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "❌ Please run as root (sudo bash install_vnet.sh)"
        exit 1
    fi
}

get_env() {  # get_env KEY  -> current value from .env (quotes removed)
    [ -f "$ENV_FILE" ] && grep -E "^$1=" "$ENV_FILE" | head -n1 | cut -d= -f2- | tr -d '"' || true
}

ask() {      # ask "Prompt" KEY  -> sets REPLY_VAL (Enter = keep current)
    local cur; cur="$(get_env "$2")"
    if [ -n "$cur" ]; then
        read -r -p "  $1 [$cur]: " REPLY_VAL
        REPLY_VAL="${REPLY_VAL:-$cur}"
    else
        read -r -p "  $1: " REPLY_VAL
    fi
}

configure_env() {
    echo ""
    echo "── Telegram Bot & API Configuration ──────────────"
    mkdir -p "$WORK_DIR"
    [ -f "$ENV_FILE" ] && echo "  ⚠ .env already exists. (Enter = keep current value)"

    ask "API_ID (my.telegram.org)" API_ID;               V_API_ID="$REPLY_VAL"
    ask "API_HASH" API_HASH;                             V_API_HASH="$REPLY_VAL"
    ask "BOT_TOKEN" BOT_TOKEN;                           V_BOT_TOKEN="$REPLY_VAL"
    ask "ADMIN_ID (Your Telegram User ID)" ADMIN_ID;     V_ADMIN_ID="$REPLY_VAL"
    ask "DB_CHANNEL_ID_1 (-100...)" DB_CHANNEL_ID_1;     V_CHANNEL="$REPLY_VAL"
    ask "Domain (e.g. stream.yourdomain.com)" DOMAIN;    V_DOMAIN="$REPLY_VAL"
    ask "TMDB_API_KEY" TMDB_API_KEY;                     V_TMDB="$REPLY_VAL"

    cat > "$ENV_FILE" <<EOF
API_ID=$V_API_ID
API_HASH=$V_API_HASH
BOT_TOKEN=$V_BOT_TOKEN
ADMIN_ID=$V_ADMIN_ID
DB_CHANNEL_ID_1=$V_CHANNEL
DOMAIN=$V_DOMAIN
PORT=$APP_PORT
PUBLIC_PORT=$NGINX_PORT
TMDB_API_KEY=$V_TMDB
EOF
    chmod 600 "$ENV_FILE"
    echo "  ✅ .env saved."
}

# stream_bot.py වල links හැදෙන්නේ https://DOMAIN:PORT (=8080) විදියට.
# ඒත් ඇත්තටම public port එක nginx 8443. ඒක නිසා PUBLIC_PORT එකක් එකතු කරලා links හරි කරනවා.
patch_bot() {
    local f="$WORK_DIR/stream_bot.py"
    [ -f "$f" ] || return 0
    if ! grep -q "^PUBLIC_PORT" "$f"; then
        sed -i 's|^PORT = int(os.getenv("PORT", 8080))\(\r\?\)$|&\nPUBLIC_PORT = int(os.getenv("PUBLIC_PORT", 8443))\1|' "$f"
    fi
    sed -i 's|https://{DOMAIN}:{PORT}|https://{DOMAIN}:{PUBLIC_PORT}|g' "$f"
    if grep -q "^PUBLIC_PORT" "$f"; then
        echo "  ✅ stream_bot.py patched (links -> :$NGINX_PORT)"
    else
        echo "  ⚠ PUBLIC_PORT patch apply වුණේ නෑ. stream_bot.py එකේ 'PORT = int(...)' පේළියට පස්සේ"
        echo "     PUBLIC_PORT = int(os.getenv(\"PUBLIC_PORT\", 8443))  කියලා අතින් එකතු කරන්න."
    fi
}

fetch_files() {
    mkdir -p "$WORK_DIR" "$SUBS_DIR" "$TEMPLATE_DIR"

    LOCAL_HTML=""
    [ -f "$SCRIPT_DIR/templates/player.html" ] && LOCAL_HTML="$SCRIPT_DIR/templates/player.html"
    [ -z "$LOCAL_HTML" ] && [ -f "$SCRIPT_DIR/player.html" ] && LOCAL_HTML="$SCRIPT_DIR/player.html"

    if [ -f "$SCRIPT_DIR/stream_bot.py" ] && [ -n "$LOCAL_HTML" ]; then
        echo "  → Local files found next to script. Using them."
        cp -f "$SCRIPT_DIR/stream_bot.py" "$WORK_DIR/stream_bot.py"
        cp -f "$LOCAL_HTML"               "$TEMPLATE_DIR/player.html"
        # CRLF -> LF (Windows වලින් ආපු files වලට)
        sed -i 's/\r$//' "$WORK_DIR/stream_bot.py" "$TEMPLATE_DIR/player.html"
        return
    fi

    echo "  → Downloading latest release from GitHub..."
    local ZIP_URL
    ZIP_URL=$(curl -s "https://api.github.com/repos/$GITHUB_REPO/releases/latest" \
        | grep -o '"browser_download_url": *"[^"]*VNET_Movies\.zip"' | cut -d '"' -f 4)
    if [ -z "$ZIP_URL" ]; then
        echo "  ❌ 'VNET_Movies.zip' asset එක latest release එකේ නෑ."
        echo "     විකල්පය: stream_bot.py + player.html මේ script එක තියෙන folder එකටම දාලා ආයෙ run කරන්න."
        exit 1
    fi
    curl -fsSL -o /tmp/vnet.zip "$ZIP_URL"
    unzip -qo /tmp/vnet.zip -d "$WORK_DIR"
    rm -f /tmp/vnet.zip
    # zip එකේ player.html root එකේ නම් templates/ එකට දානවා
    [ -f "$WORK_DIR/player.html" ] && mv -f "$WORK_DIR/player.html" "$TEMPLATE_DIR/player.html"
    echo "  ✅ Files extracted."
}

write_nginx_http() {   # HTTP :80 (ACME challenge + redirect)
    cat > /etc/nginx/sites-available/${SERVICE_NAME} <<EOF
server {
    listen 80;
    server_name $1;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host:$NGINX_PORT\$request_uri; }
}
EOF
}

write_nginx_ssl() {    # $1 domain  $2 cert  $3 key
    cat > /etc/nginx/sites-available/${SERVICE_NAME} <<EOF
server {
    listen 80;
    server_name $1;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host:$NGINX_PORT\$request_uri; }
}

server {
    listen $NGINX_PORT ssl http2;
    server_name $1;

    ssl_certificate     $2;
    ssl_certificate_key $3;
    ssl_protocols       TLSv1.2 TLSv1.3;

    client_max_body_size 50M;

    location / {
        proxy_pass         http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;

        # Video streaming (Range requests)
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF
}

setup_nginx_ssl() {
    local DOMAIN_VAL="$1"
    local LE_DIR="/etc/letsencrypt/live/$DOMAIN_VAL"
    local SS_DIR="/etc/ssl/vnet"

    ln -sf /etc/nginx/sites-available/${SERVICE_NAME} /etc/nginx/sites-enabled/${SERVICE_NAME}
    rm -f /etc/nginx/sites-enabled/default
    mkdir -p /var/www/html

    # Step 1: port 80 block එක විතරක් (certbot HTTP-01 challenge සඳහා)
    write_nginx_http "$DOMAIN_VAL"
    nginx -t && systemctl restart nginx

    # Step 2: Let's Encrypt cert (webroot)
    if [ -f "$LE_DIR/fullchain.pem" ] || \
       certbot certonly --webroot -w /var/www/html -d "$DOMAIN_VAL" \
            --non-interactive --agree-tos --register-unsafely-without-email \
            --deploy-hook "systemctl reload nginx"; then
        echo "  ✅ Let's Encrypt certificate ready."
        write_nginx_ssl "$DOMAIN_VAL" "$LE_DIR/fullchain.pem" "$LE_DIR/privkey.pem"
    else
        echo "  ⚠ Certbot fail වුණා (port 80 open ද? DNS හරිද?)."
        echo "  ⚠ Self-signed cert එකක් දානවා. Cloudflare SSL mode = 'Full' (not Strict) කරන්න."
        mkdir -p "$SS_DIR"
        [ -f "$SS_DIR/key.pem" ] || openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -keyout "$SS_DIR/key.pem" -out "$SS_DIR/cert.pem" -subj "/CN=$DOMAIN_VAL" 2>/dev/null
        write_nginx_ssl "$DOMAIN_VAL" "$SS_DIR/cert.pem" "$SS_DIR/key.pem"
    fi

    nginx -t && systemctl restart nginx
    ufw allow 80/tcp 2>/dev/null || true
    ufw allow $NGINX_PORT/tcp 2>/dev/null || true
    ufw reload 2>/dev/null || true
}

# ─────────────────────────────────────────────
# MAIN MENU
# ─────────────────────────────────────────────
check_root
clear
echo "================================================"
echo "   VNET MOVIES - STREAMING SERVER DEPLOYER"
echo "   Repo : github.com/$GITHUB_REPO"
echo "================================================"
echo "1. Full Install (Files + Nginx + SSL)"
echo "2. Update Files (Keep DB, Subs & .env)"
echo "3. Update Config (.env) & Restart"
echo "4. Uninstall"
echo "5. Check Status & Logs"
echo "6. Exit"
echo ""
read -r -p "Choose an option (1-6): " MAIN_OPT

# =====================================================================
# 1 & 2 - INSTALL / UPDATE
# =====================================================================
if [ "$MAIN_OPT" == "1" ] || [ "$MAIN_OPT" == "2" ]; then

    echo "[1/7] Installing system dependencies..."
    apt-get update -qq
    apt-get install -y python3 python3-pip python3-venv nginx certbot unzip curl openssl ffmpeg

    echo "[2/7] Fetching project files..."
    fetch_files

    echo "[3/7] Configuring environment (.env)..."
    if [ ! -f "$ENV_FILE" ]; then
        configure_env
    else
        echo "  ℹ️ Existing .env found. Keeping it."
        grep -q '^PUBLIC_PORT=' "$ENV_FILE" || echo "PUBLIC_PORT=$NGINX_PORT" >> "$ENV_FILE"
    fi
    patch_bot

    echo "[4/7] Installing Python packages..."
    cd "$WORK_DIR"
    [ -d venv ] || python3 -m venv venv
    # shellcheck disable=SC1091
    source venv/bin/activate
    pip install -q --upgrade pip
    pip install -q fastapi "uvicorn[standard]" jinja2 requests pyTelegramBotAPI \
        pyrogram tgcrypto-pyrofork python-dotenv

    echo "[5/7] Setting up systemd service..."
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=VNET Movies Streaming Server
After=network.target

[Service]
User=root
WorkingDirectory=$WORK_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$WORK_DIR/venv/bin/python stream_bot.py
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"

    if [ "$MAIN_OPT" == "1" ]; then
        echo "[6/7] Setting up Nginx..."
        DOMAIN_VAL="$(get_env DOMAIN)"
        echo "[7/7] Generating SSL certificate for $DOMAIN_VAL ..."
        echo "  ℹ️ Cloudflare Proxy (orange cloud) ON වෙලා, Cloudflare SSL mode = Full / Full (strict)."
        setup_nginx_ssl "$DOMAIN_VAL"
    else
        echo "[6/7] Nginx unchanged (update mode)."
        echo "[7/7] Done."
    fi

    DOMAIN_VAL="$(get_env DOMAIN)"
    echo ""
    echo "================================================"
    echo " ✅ INSTALLATION COMPLETE!"
    echo " 🌐 URL : https://$DOMAIN_VAL:$NGINX_PORT"
    echo " 📜 Logs: journalctl -u $SERVICE_NAME -f"
    echo "================================================"

# =====================================================================
# 3 - UPDATE ENV ONLY
# =====================================================================
elif [ "$MAIN_OPT" == "3" ]; then
    configure_env
    patch_bot
    systemctl restart "$SERVICE_NAME"
    echo "✅ .env updated and service restarted."

# =====================================================================
# 4 - UNINSTALL
# =====================================================================
elif [ "$MAIN_OPT" == "4" ]; then
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    rm -f /etc/nginx/sites-enabled/${SERVICE_NAME}
    rm -f /etc/nginx/sites-available/${SERVICE_NAME}
    systemctl daemon-reload
    systemctl restart nginx 2>/dev/null || true
    read -r -p "Delete all files in $WORK_DIR (DB, subs, session)? (y/n): " DEL_FOLD
    if [ "$DEL_FOLD" == "y" ]; then rm -rf "$WORK_DIR"; fi
    echo "✅ Uninstall complete."

# =====================================================================
# 5 - STATUS
# =====================================================================
elif [ "$MAIN_OPT" == "5" ]; then
    systemctl status "$SERVICE_NAME" --no-pager || true
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
else
    exit 0
fi

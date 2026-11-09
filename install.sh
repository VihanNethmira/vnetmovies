#!/bin/bash
# source කරන්න එපා (exit එකකදී SSH window එකම වැහෙනවා):  sudo bash deploy.sh
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "❌ Run as:  sudo bash deploy.sh   ('source' කරන්න එපා)" >&2
    return 1 2>/dev/null || exit 1
fi
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1   # apt needrestart dialog එක නවත්තනවා

# =====================================================================
# 🎬 VNET MOVIES - DEPLOYMENT TOOL  (GitHub Release -> VPS)
#   App  : stream_bot.py  (FastAPI + Pyrogram + TeleBot)
#   View : templates/player.html
#   Web  : Nginx (HTTPS :443, port නැති clean URL) -> 127.0.0.1:8080
# =====================================================================
SERVICE_NAME="vnet-bot"
APP_PORT="8080"                    # uvicorn (ඇතුළත විතරයි - nginx හරහා යන්නේ)
DEFAULT_DOMAIN="mov.vnet.store"
GITHUB_REPO="${GITHUB_REPO:-VihanNethmira/vnetmovies}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"   # private repo නම් විතරයි
ASSET_NAME="VNET_Movies.zip"       # release asset එක; නැත්නම් source zipball එක පාවිච්චි කරනවා

WORK_DIR="/var/www/vnet-movie-site"
ENV_FILE="$WORK_DIR/.env"
BACKUP_DIR="$WORK_DIR/backups"
PREV_DIR="$BACKUP_DIR/previous-release"
RUN_USER="vnet"
SITE_FILE="/etc/nginx/sites-available/${SERVICE_NAME}"
SNIPPET="/etc/nginx/snippets/vnet-proxy.conf"
TS="$(date +%Y%m%d-%H%M%S)"
SWAPPED=0
STAGE=""
SRC=""
REL_TAG=""
DB_SNAPSHOT=""

# release එකෙන් නැවත ලියවෙන්න බැරි server files
RSYNC_EXCL=(
    --exclude=/.env --exclude=/links.db --exclude=/links.db-wal --exclude=/links.db-shm
    --exclude=/links.db-journal --exclude='/*.session' --exclude='/*.session-journal'
    --exclude=/venv/ --exclude=/subs/ --exclude=/backups/ --exclude=/.release_tag
    --exclude=__pycache__/
)

# ─────────────────────────────────────────────
# HELPER FUNCTIONS
# ─────────────────────────────────────────────
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "❌ Please run as root (sudo bash deploy.sh)"
        exit 1
    fi
}

cleanup() { if [ -n "$STAGE" ]; then rm -rf "$STAGE"; fi; return 0; }
trap cleanup EXIT

get_env() {  # get_env KEY  -> .env එකේ current value (quotes / CR අයින් කරලා)
    [ -f "$ENV_FILE" ] || return 0
    grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2- | tr -d '"\r' || true
}

set_env() {  # set_env KEY VALUE  -> අනිත් keys (B2_*, STREAM_SECRET ...) අල්ලන්නේ නෑ
    local tmp; tmp="$(mktemp)"
    if [ -f "$ENV_FILE" ]; then grep -v "^$1=" "$ENV_FILE" > "$tmp" || true; fi
    printf '%s=%s\n' "$1" "$2" >> "$tmp"
    cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
}

ask() {      # ask "Prompt" KEY [optional] -> REPLY_VAL (Enter = current value තියාගන්නවා)
    local cur; cur="$(get_env "$2")"
    if [ -n "$cur" ]; then
        read -r -p "  $1 [$cur]: " REPLY_VAL
        REPLY_VAL="${REPLY_VAL:-$cur}"
    elif [ "${3:-}" == "optional" ]; then
        read -r -p "  $1 (Enter = skip): " REPLY_VAL
    else
        read -r -p "  $1: " REPLY_VAL
    fi
}

ask_set() {  # ask_set KEY "Prompt" [optional]
    ask "$2" "$1" "${3:-}"
    if [ -z "$REPLY_VAL" ]; then
        if [ "${3:-}" == "optional" ]; then return 0; fi
        echo "  ❌ $1 හිස් වෙන්න බෑ."; exit 1
    fi
    set_env "$1" "$REPLY_VAL"
}

ensure_swap() {   # RAM අඩු VPS එකක pip compile වෙද්දී OOM වෙලා SSH කඩන එක නවත්තනවා
    local mem swap
    mem=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    swap=$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)
    if [ "$mem" -lt 900 ] && [ "$swap" -lt 512 ] && [ ! -f /swapfile-vnet ]; then
        echo "  ⚠ RAM ${mem}MB විතරයි. OOM එකෙන් බේරෙන්න 1GB swap හදනවා..."
        fallocate -l 1G /swapfile-vnet 2>/dev/null || dd if=/dev/zero of=/swapfile-vnet bs=1M count=1024 status=none
        chmod 600 /swapfile-vnet; mkswap /swapfile-vnet >/dev/null; swapon /swapfile-vnet
        grep -q '/swapfile-vnet' /etc/fstab || echo '/swapfile-vnet none swap sw 0 0' >> /etc/fstab
    fi
    return 0
}

configure_env() {
    echo ""
    echo "── Telegram Bot & API Configuration ──────────────"
    mkdir -p "$WORK_DIR"
    touch "$ENV_FILE"
    sed -i 's/\r$//' "$ENV_FILE"
    echo "  ℹ️ (Enter = දැනට තියෙන value එක තියාගන්නවා. B2/CDN keys වලට අදාල නැත්නම් Enter)"

    ask_set API_ID "API_ID (my.telegram.org)"
    ask_set API_HASH "API_HASH"
    ask_set BOT_TOKEN "BOT_TOKEN"
    ask_set ADMIN_ID "ADMIN_ID (Your Telegram User ID)"
    ask_set DB_CHANNEL_ID_1 "DB_CHANNEL_ID_1 (-100...)"
    ask_set TMDB_API_KEY "TMDB_API_KEY"

    local cur_dom V_DOMAIN; cur_dom="$(get_env DOMAIN)"
    read -r -p "  Domain [${cur_dom:-$DEFAULT_DOMAIN}]: " V_DOMAIN
    V_DOMAIN="${V_DOMAIN:-${cur_dom:-$DEFAULT_DOMAIN}}"
    if ! [[ "$V_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then echo "  ❌ Domain එක වැරදියි."; exit 1; fi
    set_env DOMAIN "$V_DOMAIN"

    # Tiered storage (Backblaze B2 + Cloudflare CDN) - optional
    ask_set B2_ENDPOINT "B2_ENDPOINT (https://s3.us-east-005.backblazeb2.com)" optional
    ask_set B2_KEY_ID "B2_KEY_ID" optional
    ask_set B2_APP_KEY "B2_APP_KEY" optional
    ask_set B2_BUCKET "B2_BUCKET" optional
    ask_set CDN_BASE_URL "CDN_BASE_URL (https://cdn.vnet.store)" optional

    # STREAM_SECRET නැත්නම් හදනවා (නැතුව restart වෙද්දී සේරම links අවලංගු වෙනවා)
    if [ -z "$(get_env STREAM_SECRET)" ]; then
        set_env STREAM_SECRET "$(openssl rand -hex 32)"
        echo "  🔑 STREAM_SECRET auto-generated."
    fi
    set_env PORT "$APP_PORT"
    set_env PUBLIC_BASE_URL "https://$V_DOMAIN"
    chmod 600 "$ENV_FILE"
    echo "  ✅ .env saved."
}

# stream_bot.py වල links හැදෙන්නේ https://DOMAIN:PORT (=8080) විදියට. Nginx හරහා port නැතුව යන නිසා
# ':PORT' කොටස අයින් කරනවා (release එක update වෙන හැම වතාවකම ආයෙ apply වෙනවා).
patch_bot() {
    local f="$WORK_DIR/stream_bot.py"
    [ -f "$f" ] || return 0
    if grep -q 'https://{DOMAIN}:{PORT}' "$f"; then
        sed -i 's|https://{DOMAIN}:{PORT}|https://{DOMAIN}|g' "$f"
        echo "  ✅ stream_bot.py patched (links -> https://$(get_env DOMAIN), port නැතුව)"
    else
        echo "  ℹ️ stream_bot.py links patch අවශ්‍ය නෑ."
    fi
    # uvicorn localhost එකට විතරක් bind කරනවා -> http://IP:8080 පිටින් කෙළින්ම යන්න බෑ, nginx හරහා විතරයි
    if grep -q 'uvicorn.run(app, host="0.0.0.0"' "$f"; then
        sed -i 's|uvicorn.run(app, host="0.0.0.0"|uvicorn.run(app, host="127.0.0.1"|' "$f"
        echo "  ✅ stream_bot.py patched (uvicorn -> 127.0.0.1:$APP_PORT)"
    fi
    return 0
}

fix_permissions() {
    id "$RUN_USER" >/dev/null 2>&1 || useradd --system --home-dir "$WORK_DIR" --shell /usr/sbin/nologin "$RUN_USER"
    mkdir -p "$WORK_DIR/subs" "$WORK_DIR/templates" "$BACKUP_DIR"
    chown -R "$RUN_USER:$RUN_USER" "$WORK_DIR"
    find "$WORK_DIR" -path "$WORK_DIR/venv" -prune -o -type d -exec chmod 755 {} +
    if [ -f "$ENV_FILE" ]; then chmod 600 "$ENV_FILE"; fi
    # SQLite වලට file එක විතරක් නෙවෙයි, folder එකත් writable වෙන්න ඕනේ
    for f in "$WORK_DIR"/links.db*; do if [ -e "$f" ]; then chmod 660 "$f"; fi; done
    return 0
}

fetch_files() {
    STAGE="$(mktemp -d /tmp/vnet-stage.XXXXXX)"
    local auth=()
    if [ -n "$GITHUB_TOKEN" ]; then auth=(-H "Authorization: Bearer $GITHUB_TOKEN"); fi

    echo "  → GitHub: $GITHUB_REPO (latest release)"
    local http
    http=$(curl -sS -o "$STAGE/release.json" -w '%{http_code}' --retry 3 --max-time 30 \
        -H "Accept: application/vnd.github+json" "${auth[@]}" \
        "https://api.github.com/repos/$GITHUB_REPO/releases/latest") || { echo "  ❌ GitHub එකට connect වෙන්න බෑ."; exit 1; }
    case "$http" in
        200) ;;
        404) echo "  ❌ Published release එකක් නෑ (repo private නම් GITHUB_TOKEN=... දෙන්න)."
             echo "     GitHub -> Releases -> Draft a new release කරලා ආයෙ run කරන්න."; exit 1 ;;
        403|429) echo "  ❌ GitHub API rate limit. GITHUB_TOKEN=... දාලා ආයෙ try කරන්න."; exit 1 ;;
        *) echo "  ❌ GitHub API HTTP $http"; exit 1 ;;
    esac

    REL_TAG="$(jq -r '.tag_name' "$STAGE/release.json")"
    local asset_api zip_url
    asset_api="$(jq -r --arg n "$ASSET_NAME" '[.assets[]? | select(.name==$n)][0].url // empty' "$STAGE/release.json")"
    zip_url="$(jq -r '.zipball_url' "$STAGE/release.json")"
    echo "  → Release: $REL_TAG (දැනට: $(cat "$WORK_DIR/.release_tag" 2>/dev/null || echo none))"

    if [ -n "$asset_api" ]; then
        echo "  → Downloading asset $ASSET_NAME"
        curl -fL --retry 3 --max-time 600 -H "Accept: application/octet-stream" "${auth[@]}" -o "$STAGE/release.zip" "$asset_api"
    else
        echo "  → '$ASSET_NAME' asset එක නෑ. Source zip එක download කරනවා."
        curl -fL --retry 3 --max-time 600 -H "Accept: application/vnd.github+json" "${auth[@]}" -o "$STAGE/release.zip" "$zip_url"
    fi
    unzip -tq "$STAGE/release.zip" >/dev/null || { echo "  ❌ Zip එක corrupt."; exit 1; }
    mkdir -p "$STAGE/src"
    unzip -q "$STAGE/release.zip" -d "$STAGE/src"
    SRC="$STAGE/src"
    local top; top="$(find "$SRC" -mindepth 1 -maxdepth 1)"
    if [ "$(echo "$top" | wc -l)" -eq 1 ] && [ -d "$top" ]; then SRC="$top"; fi   # GitHub zipball wrapper folder

    [ -f "$SRC/stream_bot.py" ] || { echo "  ❌ stream_bot.py release එකේ නෑ."; exit 1; }
    # zip එකේ player.html root එකේ නම් templates/ එකට දානවා
    if [ -f "$SRC/player.html" ] && [ ! -f "$SRC/templates/player.html" ]; then
        mkdir -p "$SRC/templates"; mv -f "$SRC/player.html" "$SRC/templates/player.html"
    fi
    if [ -f "$SRC/templates/player.html" ]; then
        sed -i 's/\r$//' "$SRC/templates/player.html"
    else
        echo "  ⚠ templates/player.html release එකේ නෑ!"
    fi
    # CRLF -> LF (Windows වලින් ආපු files වලට)
    sed -i 's/\r$//' "$SRC"/*.py 2>/dev/null || true
    echo "  ✅ Release ready."
    return 0
}

install_python() {
    cd "$WORK_DIR"
    [ -x venv/bin/python ] || python3 -m venv venv
    # shellcheck disable=SC1091
    source venv/bin/activate
    pip install -q --upgrade pip wheel
    if [ -f "$SRC/requirements.txt" ]; then
        nice -n 10 pip install -q --no-cache-dir -r "$SRC/requirements.txt"
    else
        echo "  ⚠ requirements.txt නෑ - default package list එක පාවිච්චි කරනවා."
        nice -n 10 pip install -q --no-cache-dir fastapi "uvicorn[standard]" jinja2 requests pyTelegramBotAPI \
            pyrogram tgcrypto-pyrofork python-dotenv boto3
    fi
    python -m py_compile "$SRC/stream_bot.py" || { echo "  ❌ stream_bot.py syntax error - live site එක අල්ලන්නේ නෑ."; exit 1; }
    deactivate
}

app_healthy() {
    local code
    for _ in $(seq 1 90); do
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$APP_PORT/" || true)"
            if [ -n "$code" ] && [ "$code" != "000" ]; then return 0; fi
        fi
        sleep 1
    done
    return 1
}

rollback() {
    trap - ERR
    echo "  ⚠ Rolling back to previous release..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    if [ -d "$PREV_DIR" ]; then
        rsync -a --delete "${RSYNC_EXCL[@]}" "$PREV_DIR"/ "$WORK_DIR"/
        fix_permissions
        systemctl start "$SERVICE_NAME" || true
        echo "  ⚠ පරණ code එක restore කළා. DB backup: ${DB_SNAPSHOT:-none}"
    fi
}
on_err() {
    echo "❌ Failed at line $1" >&2
    if [ "$SWAPPED" -eq 1 ]; then SWAPPED=0; rollback; fi
}
trap 'on_err $LINENO' ERR

apply_files() {
    echo "  → Stopping $SERVICE_NAME"
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    mkdir -p "$BACKUP_DIR"
    DB_SNAPSHOT=""
    if [ -f "$WORK_DIR/links.db" ]; then
        DB_SNAPSHOT="$BACKUP_DIR/links-$TS.db"
        sqlite3 "$WORK_DIR/links.db" ".backup '$DB_SNAPSHOT'"
        echo "  💾 DB backup: $DB_SNAPSHOT"
        # shellcheck disable=SC2012
        ls -1t "$BACKUP_DIR"/links-*.db 2>/dev/null | tail -n +8 | xargs -r rm -f
    fi
    mkdir -p "$PREV_DIR"
    rsync -a --delete "${RSYNC_EXCL[@]}" "$WORK_DIR"/ "$PREV_DIR"/
    SWAPPED=1
    rsync -a --delete "${RSYNC_EXCL[@]}" "$SRC"/ "$WORK_DIR"/
    echo "$REL_TAG" > "$WORK_DIR/.release_tag"
    patch_bot
    fix_permissions
    echo "  ✅ Files synced ($REL_TAG)."
}

write_service() {
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=VNET Movies - FastAPI + Telegram bot
After=network-online.target
Wants=network-online.target

[Service]
User=$RUN_USER
Group=$RUN_USER
WorkingDirectory=$WORK_DIR
Environment=PYTHONUNBUFFERED=1
ExecStart=$WORK_DIR/venv/bin/python stream_bot.py
Restart=always
RestartSec=5
LimitNOFILE=65535
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
}

write_proxy_snippet() {
    mkdir -p /etc/nginx/snippets
    cat > "$SNIPPET" <<EOF
proxy_pass         http://127.0.0.1:$APP_PORT;
proxy_http_version 1.1;
proxy_set_header   Host \$host;
proxy_set_header   X-Real-IP \$remote_addr;
proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
proxy_set_header   X-Forwarded-Proto \$scheme;
proxy_set_header   X-Forwarded-Host \$host;
proxy_set_header   Connection "";

# Video streaming (Range requests ඒ විදියටම යනවා, disk buffer නෑ)
proxy_buffering off;
proxy_request_buffering off;
proxy_read_timeout 3600s;
proxy_send_timeout 3600s;
EOF
}

write_nginx_http() {   # $1 domain  - cert එක ගන්නකම් HTTP :80 එකෙන්ම site එක වැඩ කරනවා
    cat > "$SITE_FILE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $1;
    server_tokens off;
    client_max_body_size 50M;

    location / {
        include snippets/vnet-proxy.conf;
    }
}
EOF
}

write_nginx_ssl() {    # $1 domain  $2 cert  $3 key
    cat > "$SITE_FILE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $1;
    server_tokens off;
    return 301 https://$1\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $1;
    server_tokens off;
    client_max_body_size 50M;

    ssl_certificate     $2;
    ssl_certificate_key $3;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:vnet_ssl:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    add_header Strict-Transport-Security "max-age=15552000" always;

    location / {
        include snippets/vnet-proxy.conf;
    }
}
EOF
}

nginx_apply() {   # test -> reload. fail වුණොත් පරණ config එක restore කරනවා
    if nginx -t >/tmp/vnet-nginx-test.log 2>&1; then
        systemctl enable nginx >/dev/null 2>&1
        systemctl reload-or-restart nginx
    else
        cat /tmp/vnet-nginx-test.log >&2
        if [ -f "$SITE_FILE.bak" ]; then cp -f "$SITE_FILE.bak" "$SITE_FILE"; fi
        echo "❌ nginx config test fail වුණා."; exit 1
    fi
}

setup_firewall() {
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
        local sp; sp="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
        ufw allow "${sp:-22}/tcp" >/dev/null || true       # SSH කවදාවත් වහන්නේ නෑ
        ufw allow 'Nginx Full' >/dev/null || true
        ufw deny "$APP_PORT/tcp" >/dev/null || true
        ufw delete allow 8443/tcp >/dev/null 2>&1 || true   # පරණ :8443 setup එක
        echo "  ✅ ufw: 80/443 open, $APP_PORT closed (nginx localhost හරහා යනවා)."
    else
        echo "  ℹ️ ufw active නෑ. uvicorn 127.0.0.1 එකට bind වෙන නිසා $APP_PORT පිටින් නෑ."
        echo "     Linode Cloud Firewall තියෙනවා නම් 80/443 inbound allow කරන්න."
    fi
}

OLD_CERT=""; OLD_KEY=""

preflight_ports() {   # 443 වල වෙන service එකක් (xray ආදී) ඉන්නවා නම් නවත්තනවා
    local owner
    owner="$(ss -tlnpH 'sport = :443' 2>/dev/null | grep -v '"nginx"' || true)"
    if [ -n "$owner" ]; then
        echo "❌ Port 443 දැනටමත් වෙන program එකක් පාවිච්චි කරනවා:" >&2
        echo "$owner" >&2
        echo "   ඒක නවත්තන්න (උදා: systemctl disable --now xray) ඊට පස්සේ ආයෙ run කරන්න." >&2
        exit 1
    fi
}

adopt_old_nginx() {   # පරණ :8443 nginx sites අයින් කරලා, ඒවායේ cert එක ගන්නවා
    local f hit=0 bdir="/root/nginx-old-$TS"
    for f in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
        [ -e "$f" ] || continue
        [ "$(basename "$f")" == "$SERVICE_NAME" ] && continue
        grep -Eq 'listen[^;]*:?8443' "$f" || continue
        hit=1
        mkdir -p "$bdir"
        local real; real="$(readlink -f "$f")"
        local c k
        c="$(grep -E '^\s*ssl_certificate\s' "$real" | head -n1 | awk '{print $2}' | tr -d ';')"
        k="$(grep -E '^\s*ssl_certificate_key\s' "$real" | head -n1 | awk '{print $2}' | tr -d ';')"
        if [ -z "$OLD_CERT" ] && [ -f "$c" ] && [ -f "$k" ] \
           && openssl x509 -in "$c" -noout -subject 2>/dev/null | grep -q "$DOMAIN_VAL"; then
            OLD_CERT="$c"; OLD_KEY="$k"
        fi
        cp -a "$real" "$bdir/"
        rm -f "$f"
        echo "  🧹 පරණ :8443 nginx config අයින් කළා: $f (backup: $bdir)"
    done
    [ "$hit" -eq 1 ] || echo "  ℹ️ පරණ :8443 nginx config නෑ."
    return 0
}

setup_nginx_ssl() {
    local DOMAIN_VAL="$1"
    preflight_ports
    adopt_old_nginx
    local LE_DIR="/etc/letsencrypt/live/$DOMAIN_VAL"
    local SS_DIR="/etc/ssl/vnet"
    local email_args=(--register-unsafely-without-email)

    if [ -n "${CERTBOT_EMAIL:-}" ]; then
        email_args=(--email "$CERTBOT_EMAIL")
    elif [ ! -f "$LE_DIR/fullchain.pem" ]; then
        read -r -p "  Let's Encrypt email (expiry notices) (Enter = skip): " LE_EMAIL
        if [ -n "$LE_EMAIL" ]; then email_args=(--email "$LE_EMAIL"); fi
    fi

    if [ -f "$SITE_FILE" ]; then cp -f "$SITE_FILE" "$SITE_FILE.bak"; fi
    write_proxy_snippet
    ln -sf "$SITE_FILE" /etc/nginx/sites-enabled/${SERVICE_NAME}
    rm -f /etc/nginx/sites-enabled/default

    # Step 1: HTTP :80 (site එක + certbot challenge)
    write_nginx_http "$DOMAIN_VAL"
    nginx_apply

    # DNS check (Cloudflare proxy නම් වෙනස් IP එකක් එන එක සාමාන්‍යයි)
    local dns_ips my_ip
    dns_ips="$(dig +short A "$DOMAIN_VAL" | tr '\n' ' ')"
    my_ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    if [ -z "$dns_ips" ]; then
        echo "  ⚠ $DOMAIN_VAL සඳහා A record එකක් නෑ - Let's Encrypt fail වෙයි."
    elif [ -n "$my_ip" ] && [[ "$dns_ips" != *"$my_ip"* ]]; then
        echo "  ℹ️ DNS -> $dns_ips | server -> $my_ip (Cloudflare proxy නම් ok)"
    fi

    # Step 2: cert. LE cert එක තියෙනවා නම් / ඒක නැතුව පරණ nginx cert එක තියෙනවා නම් ඒක පාවිච්චි කරනවා.
    if [ ! -f "$LE_DIR/fullchain.pem" ] && [ -n "$OLD_CERT" ]; then
        echo "  ✅ පරණ cert එකම පාවිච්චි කරනවා: $OLD_CERT"
        write_nginx_ssl "$DOMAIN_VAL" "$OLD_CERT" "$OLD_KEY"
    elif certbot certonly --nginx -d "$DOMAIN_VAL" --non-interactive --agree-tos \
            --keep-until-expiring "${email_args[@]}" --deploy-hook "systemctl reload nginx"; then
        echo "  ✅ Let's Encrypt certificate ready."
        write_nginx_ssl "$DOMAIN_VAL" "$LE_DIR/fullchain.pem" "$LE_DIR/privkey.pem"
        systemctl enable --now certbot.timer >/dev/null 2>&1 || echo "  ⚠ certbot.timer නෑ - 'certbot renew' cron එකක් දාන්න."
    else
        echo "  ⚠ Certbot fail වුණා (port 80 open ද? DNS හරිද?)."
        echo "  ⚠ Self-signed cert එකක් දානවා. Cloudflare SSL mode = 'Full' (not Strict) කරන්න."
        mkdir -p "$SS_DIR"
        [ -f "$SS_DIR/key.pem" ] || openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -keyout "$SS_DIR/key.pem" -out "$SS_DIR/cert.pem" -subj "/CN=$DOMAIN_VAL" 2>/dev/null
        write_nginx_ssl "$DOMAIN_VAL" "$SS_DIR/cert.pem" "$SS_DIR/key.pem"
    fi
    nginx_apply
    setup_firewall
    echo "  → Verify: https://$DOMAIN_VAL"
    local code; code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 --resolve "$DOMAIN_VAL:443:127.0.0.1" "https://$DOMAIN_VAL/" || true)"
    echo "     nginx:443 -> app HTTP $code  ($(ss -tlnH 'sport = :443' | wc -l) listener)"
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
echo "2. Update Files (Keep DB, Subs, Sessions & .env)"
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
    ensure_swap
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends python3 python3-pip python3-venv python3-dev build-essential \
        nginx certbot python3-certbot-nginx unzip curl jq rsync sqlite3 openssl ffmpeg dnsutils ca-certificates

    echo "[2/7] Downloading latest release..."
    mkdir -p "$WORK_DIR"
    fetch_files

    echo "[3/7] Configuring environment (.env)..."
    if [ ! -f "$ENV_FILE" ]; then
        configure_env
    else
        echo "  ℹ️ Existing .env found. Keeping it."
        sed -i 's/\r$//' "$ENV_FILE"
        if [ -z "$(get_env STREAM_SECRET)" ]; then set_env STREAM_SECRET "$(openssl rand -hex 32)"; fi
        if [ -z "$(get_env DOMAIN)" ]; then set_env DOMAIN "$DEFAULT_DOMAIN"; fi
        if [ -z "$(get_env PUBLIC_BASE_URL)" ]; then set_env PUBLIC_BASE_URL "https://$(get_env DOMAIN)"; fi
        if [ -z "$(get_env PORT)" ]; then set_env PORT "$APP_PORT"; fi
    fi
    APP_PORT="$(get_env PORT)"; APP_PORT="${APP_PORT:-8080}"
    DOMAIN_VAL="$(get_env DOMAIN)"; DOMAIN_VAL="${DOMAIN_VAL:-$DEFAULT_DOMAIN}"

    echo "[4/7] Installing Python packages..."
    install_python

    echo "[5/7] Applying files & permissions..."
    write_service
    apply_files

    echo "[6/7] Starting $SERVICE_NAME..."
    systemctl restart "$SERVICE_NAME"
    if app_healthy; then
        SWAPPED=0
        echo "  ✅ App 127.0.0.1:$APP_PORT එකේ answer කරනවා."
    else
        journalctl -u "$SERVICE_NAME" -n 40 --no-pager >&2 || true
        if [ "$SWAPPED" -eq 1 ]; then SWAPPED=0; rollback; fi
        echo "❌ $SERVICE_NAME start වුණේ නෑ."; exit 1
    fi

    if [ "$MAIN_OPT" == "1" ] || [ ! -f "$SITE_FILE" ]; then
        echo "[7/7] Setting up Nginx + SSL for $DOMAIN_VAL ..."
        echo "  ℹ️ Cloudflare Proxy (orange cloud) නම් SSL mode = Full / Full (strict)."
        setup_nginx_ssl "$DOMAIN_VAL"
    else
        echo "[7/7] Nginx unchanged (update mode)."
    fi

    echo ""
    echo "================================================"
    echo " ✅ DEPLOYMENT COMPLETE!  ($REL_TAG)"
    echo " 🌐 URL : https://$DOMAIN_VAL"
    echo " 📜 Logs: journalctl -u $SERVICE_NAME -f"
    echo "================================================"

# =====================================================================
# 3 - UPDATE ENV ONLY
# =====================================================================
elif [ "$MAIN_OPT" == "3" ]; then
    configure_env
    patch_bot
    fix_permissions
    systemctl restart "$SERVICE_NAME"
    echo "✅ .env updated and service restarted."

# =====================================================================
# 4 - UNINSTALL
# =====================================================================
elif [ "$MAIN_OPT" == "4" ]; then
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    rm -f /etc/nginx/sites-enabled/${SERVICE_NAME} "$SITE_FILE" "$SITE_FILE.bak" "$SNIPPET"
    systemctl daemon-reload
    if nginx -t 2>/dev/null; then systemctl reload nginx 2>/dev/null || true; fi
    read -r -p "Delete all files in $WORK_DIR (DB, subs, session, .env)? (y/n): " DEL_FOLD
    if [ "$DEL_FOLD" == "y" ]; then rm -rf "$WORK_DIR"; fi
    echo "✅ Uninstall complete. (SSL certs /etc/letsencrypt එකේ ඒ විදියටම තියෙනවා)"

# =====================================================================
# 5 - STATUS
# =====================================================================
elif [ "$MAIN_OPT" == "5" ]; then
    systemctl status "$SERVICE_NAME" --no-pager || true
    systemctl status nginx --no-pager | head -n 5 || true
    certbot certificates 2>/dev/null | grep -E "Domains|Expiry" || true
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
else
    exit 0
fi

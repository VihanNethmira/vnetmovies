#!/bin/bash
# source කරන්න එපා (exit එකකදී SSH window එකම වැහෙනවා):  sudo bash install.sh
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "❌ Run as:  sudo bash install.sh   ('source' කරන්න එපා)" >&2
    return 1 2>/dev/null || exit 1
fi
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1   # apt needrestart dialog එක නවත්තනවා

# =====================================================================
# 🎬 VNET MOVIES - DEPLOYMENT TOOL  (GitHub Release -> VPS)
#   App  : stream_bot.py  (FastAPI + Pyrogram + TeleBot)
#   View : templates/player.html
#   Web  : Nginx (HTTPS :443, port නැති clean URL) -> 127.0.0.1:8080
#   CDN  : Backblaze B2 (private) + Cloudflare Worker (cdn_worker.js)
#
#   CDN traffic එන්න ඕනේ දේවල් (මේ script එක හැම එකක්ම කරනවා):
#     1. tiered_storage.py + apply_patches.py -> stream_bot.py patch (player එකට "cdn" source එක යන්න)
#     2. boto3 installed
#     3. CDN_BASE_URL = Cloudflare Universal SSL cover වෙන hostname එකක් (cdn.vnet.store)
#     4. Worker deploy (custom domain + STREAM_SECRET/B2 secrets)
#     5. End-to-end test: B2 එකට test object එකක් දාලා CDN URL එකෙන් ගන්න බලනවා
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # tiered_storage.py ආදිය release එකේ නැත්නම් මෙතනින් ගන්නවා
CDN_DIR="/opt/vnet-cdn-worker"     # wrangler project (WORK_DIR එකෙන් පිටත, rsync --delete එකෙන් බේරෙන්න)
WORKER_NAME="vnet-cdn"
TS="$(date +%Y%m%d-%H%M%S)"
SWAPPED=0
STAGE=""
SRC=""
REL_TAG=""
DB_SNAPSHOT=""
TIERED_OK=0
CDN_ENV_CHANGED=0
CF_TOKEN=""

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
        echo "❌ Please run as root (sudo bash install.sh)"
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

# CDN hostname එක site domain එකේ ඇතුළේ නම් (cdn.mov.vnet.store) Cloudflare Free Universal SSL (*.vnet.store)
# cover කරන්නේ නෑ -> TLS fail වෙලා player එක Telegram එකට fallback වෙනවා. cdn.vnet.store වගේ එකක් යෝජනා කරනවා.
check_cdn_host() {
    local base host dom parent ans
    base="$(get_env CDN_BASE_URL)"
    [ -n "$base" ] || return 0
    host="${base#*://}"; host="${host%%/*}"
    dom="$(get_env DOMAIN)"
    if [ -n "$dom" ] && [[ "$dom" == *.*.* ]] && [[ "$host" == *".$dom" ]]; then
        parent="${dom#*.}"
        echo "  ⚠ $host කියන්නේ level දෙකක් ගැඹුරු hostname එකක්. Cloudflare Free SSL එක (*.$parent) ඒක cover කරන්නේ නෑ."
        read -r -p "  → https://cdn.$parent පාවිච්චි කරන්නද? (Y/n): " ans || ans="y"
        if [[ ! "$ans" =~ ^[Nn] ]]; then
            set_env CDN_BASE_URL "https://cdn.$parent"
            CDN_ENV_CHANGED=1
            echo "  ✅ CDN_BASE_URL = https://cdn.$parent"
        fi
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
    check_cdn_host

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

# tiered_storage.py / apply_patches.py / cdn_worker.js release එකේ නැත්නම් rsync --delete එකෙන් මැකෙනවා.
# ඒ නිසා නැති ඒවා install.sh තියෙන folder එකෙන් (නැත්නම් පරණ release එකෙන්) ආපහු දානවා.
restore_tiered_files() {
    local f
    for f in tiered_storage.py apply_patches.py cdn_worker.js; do
        if [ -f "$WORK_DIR/$f" ]; then continue; fi
        if [ -f "$SCRIPT_DIR/$f" ]; then
            cp -f "$SCRIPT_DIR/$f" "$WORK_DIR/$f"; echo "  ➕ $f (install.sh තියෙන folder එකෙන්)"
        elif [ -f "$PREV_DIR/$f" ]; then
            cp -f "$PREV_DIR/$f" "$WORK_DIR/$f"; echo "  ➕ $f (පරණ release එකෙන්)"
        fi
    done
    return 0
}

# stream_bot.py එකට tiered storage wire කරනවා (idempotent). මේක නැතුව player එකට CDN source එක කිසිදාක යන්නේ නෑ.
patch_tiered() {
    local bot="$WORK_DIR/stream_bot.py"
    TIERED_OK=0
    [ -f "$bot" ] || return 0
    restore_tiered_files
    if [ ! -f "$WORK_DIR/tiered_storage.py" ] || [ ! -f "$WORK_DIR/apply_patches.py" ]; then
        echo "  ⚠ tiered_storage.py / apply_patches.py නෑ (release එකේ හෝ install.sh ළඟ දාන්න). CDN source එක player එකට එන්නේ නෑ!"
        return 0
    fi
    if python3 "$WORK_DIR/apply_patches.py" "$bot"; then
        if python3 -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$bot"; then
            TIERED_OK=1
            echo "  ✅ tiered storage wired into stream_bot.py"
        else
            echo "  ❌ Patch කළාට පස්සේ stream_bot.py syntax error. .bak එකෙන් restore කරනවා."
            if [ -f "$bot.bak" ]; then cp -f "$bot.bak" "$bot"; fi
        fi
    else
        echo "  ⚠ apply_patches.py fail වුණා (ඔයාගේ stream_bot.py එකේ anchor එකක් වෙනස්). උඩ පණිවිඩය බලන්න."
        echo "    Site එක tiered storage නැතුව දිගටම වැඩ කරනවා."
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
    # tiered_storage.py ට boto3 ඕනේ (requirements.txt එකේ නැතුව ඇති)
    python -c 'import boto3' 2>/dev/null || nice -n 10 pip install -q --no-cache-dir boto3
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
    patch_tiered
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
# CLOUDFLARE CDN WORKER  (B2 private bucket -> Worker -> player)
# ─────────────────────────────────────────────
cf_api() { curl -fsS --max-time 20 -H "Authorization: Bearer $CF_TOKEN" "https://api.cloudflare.com/client/v4/$1"; }

ensure_node() {   # wrangler ට Node 20+ ඕනේ
    local v=0
    if command -v node >/dev/null 2>&1; then
        v="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    fi
    if [ "$v" -lt 20 ]; then
        echo "  → Node.js 22 (NodeSource) install කරනවා (wrangler සඳහා)..."
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
        apt-get install -y -qq nodejs
    fi
    command -v npx >/dev/null 2>&1 || { echo "  ❌ npx නෑ."; return 1; }
    return 0
}

# End-to-end test: B2 එකට test object එකක් ලියලා, CDN URL එකෙන් (token + Origin + Range සමඟ) ගන්න බලනවා.
verify_cdn() {
    local py="$WORK_DIR/venv/bin/python" base cdn_host
    [ -x "$py" ] || { echo "  ⚠ venv නෑ - verify skip."; return 0; }
    base="$(get_env CDN_BASE_URL)"; base="${base%/}"
    echo "  → End-to-end test: $base"
    local rc=0
    env B2_ENDPOINT="$(get_env B2_ENDPOINT)" B2_KEY_ID="$(get_env B2_KEY_ID)" \
        B2_APP_KEY="$(get_env B2_APP_KEY)" B2_BUCKET="$(get_env B2_BUCKET)" \
        STREAM_SECRET="$(get_env STREAM_SECRET)" CDN_BASE="$base" \
        SITE_ORIGIN="https://$(get_env DOMAIN)" \
        "$py" - <<'PY' || rc=$?
import os, sys, time, hmac, hashlib, urllib.request, urllib.error
import boto3
from botocore.config import Config

E = os.environ
region = E["B2_ENDPOINT"].split("//", 1)[-1].split(".")[1]
kw = dict(signature_version="s3v4", retries={"max_attempts": 2})
try:   # B2 අලුත් boto3 default checksums අල්ලන්නේ නෑ
    cfg = Config(request_checksum_calculation="when_required",
                 response_checksum_validation="when_required", **kw)
except TypeError:
    cfg = Config(**kw)
s3 = boto3.client("s3", endpoint_url=E["B2_ENDPOINT"], region_name=region,
                  aws_access_key_id=E["B2_KEY_ID"], aws_secret_access_key=E["B2_APP_KEY"], config=cfg)
bucket, secret, base, origin = E["B2_BUCKET"], E["STREAM_SECRET"], E["CDN_BASE"], E["SITE_ORIGIN"]

slug, msg = "healthcheck", str(int(time.time()))
key = f"v/{slug}/{msg}"
body = os.urandom(4096)

def token(ttl=600):
    exp = int(time.time()) + ttl
    sig = hmac.new(secret.encode(), f"{slug}:{exp}".encode(), hashlib.sha256).hexdigest()
    return f"{exp}.{sig}"

def get(url, headers):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 vnet-check", **headers})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.read(), None
    except urllib.error.HTTPError as e:
        return e.code, e.read(), None
    except Exception as e:
        return 0, b"", e

def cleanup():
    try:
        r = s3.list_object_versions(Bucket=bucket, Prefix=key)
        for v in r.get("Versions", []) + r.get("DeleteMarkers", []):
            if v["Key"] == key:
                s3.delete_object(Bucket=bucket, Key=key, VersionId=v["VersionId"])
    except Exception as e:
        print(f"  ⚠ test object cleanup fail: {e}")

try:
    s3.put_object(Bucket=bucket, Key=key, Body=body, ContentType="video/mp4")
except Exception as e:
    print(f"  ❌ B2 write fail (.env හි B2_ENDPOINT / B2_KEY_ID / B2_APP_KEY / B2_BUCKET බලන්න): {e}")
    sys.exit(2)
print("  ✅ B2 bucket write OK")

url = f"{base}/v/{slug}/{msg}?t={token()}"
ok, st, err, auth_fails = False, 0, None, 0
for i in range(18):                       # custom domain DNS + cert propagate වෙන්න විනාඩි 2-3ක් යන්න පුළුවන්
    st, data, err = get(url, {"Origin": origin, "Range": "bytes=0-99"})
    if st in (200, 206) and data[:100] == body[:100]:
        ok = True
        break
    if st in (403, 404):
        auth_fails += 1
        if auth_fails >= 4:
            break
    print(f"     … try {i + 1}: HTTP {st or 'no-connection'} {('(' + str(err)[:80] + ')') if err else ''}")
    time.sleep(10 if st not in (403, 404) else 5)

code = 0
if ok:
    print(f"  ✅ CDN OK: HTTP {st}, bytes match (Range + Origin + token හරි)")
    bad, _, _ = get(f"{base}/v/{slug}/{msg}?t=1.{'0' * 64}", {"Origin": origin})
    print(f"  ✅ bad token -> HTTP {bad} (403 වෙන්න ඕනේ)" if bad == 403 else f"  ⚠ bad token -> HTTP {bad} (403 බලාපොරොත්තු වුණා)")
else:
    code = 3
    if st == 0:
        print(f"  ❌ CDN එකට connect වෙන්න බෑ: {err}")
        print("     • 'Name or service not known' -> DNS record නෑ (Worker custom domain bind වුණේ නෑ / zone Cloudflare එකේ නෑ)")
        print("     • SSL error -> hostname එක Universal SSL cover කරන්නේ නෑ (cdn.vnet.store පාවිච්චි කරන්න), නැත්නම් cert තාම හැදෙනවා")
    elif st == 403:
        print("  ❌ HTTP 403: Worker එකේ STREAM_SECRET එක .env එකේ එකට වඩා වෙනස්, නැත්නම් Origin allow-list (ALLOWED_ORIGINS) වැරදියි.")
    elif st == 404:
        print("  ❌ HTTP 404: Worker එකට B2 object එක කියවන්න බෑ -> Worker secrets B2_KEY_ID/B2_APP_KEY, B2_BUCKET/B2_HOST/B2_REGION බලන්න.")
    else:
        print(f"  ❌ HTTP {st}. Worker logs: cd /opt/vnet-cdn-worker && npx wrangler tail")
cleanup()
sys.exit(code)
PY
    return "$rc"
}

# return: 0 = deployed+verified, 1 = failed, 2 = skipped
deploy_cdn_worker() {
    local k
    for k in B2_ENDPOINT B2_KEY_ID B2_APP_KEY B2_BUCKET CDN_BASE_URL STREAM_SECRET DOMAIN; do
        if [ -z "$(get_env "$k")" ]; then
            echo "  ⚠ .env හි $k නෑ -> CDN worker skip. (Menu 3 එකෙන් B2/CDN values දාන්න)"
            return 2
        fi
    done
    check_cdn_host

    local cdn_host b2_host b2_region js=""
    cdn_host="$(get_env CDN_BASE_URL)"; cdn_host="${cdn_host#*://}"; cdn_host="${cdn_host%%/*}"
    b2_host="$(get_env B2_ENDPOINT)"; b2_host="${b2_host#*://}"; b2_host="${b2_host%%/*}"
    b2_region="$(sed -nE 's/^s3\.([^.]+)\.backblazeb2\.com$/\1/p' <<<"$b2_host")"
    if [ -z "$b2_region" ]; then
        echo "  ❌ B2_ENDPOINT ($b2_host) එකෙන් region එක ගන්න බෑ. (උදා: https://s3.us-east-005.backblazeb2.com)"
        return 1
    fi
    for k in "$WORK_DIR/cdn_worker.js" "$SCRIPT_DIR/cdn_worker.js"; do
        if [ -f "$k" ]; then js="$k"; break; fi
    done
    if [ -z "$js" ]; then echo "  ❌ cdn_worker.js නෑ (release එකේ හෝ install.sh ළඟ දාන්න)."; return 1; fi

    # ── Cloudflare API token ──
    CF_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
    if [ -z "$CF_TOKEN" ]; then
        echo "  ℹ️ Cloudflare API token: dash.cloudflare.com/profile/api-tokens -> 'Edit Cloudflare Workers' template"
        echo "     (custom domain fail වුණොත් Zone -> DNS -> Edit permission එකත් දාන්න)"
        read -r -s -p "  Cloudflare API token (Enter = Worker deploy skip): " CF_TOKEN || CF_TOKEN=""
        echo ""
    fi
    if [ -z "$CF_TOKEN" ]; then echo "  ⏭ Worker deploy skip කළා."; return 2; fi
    if [ "$(cf_api "user/tokens/verify" 2>/dev/null | jq -r '.success // false')" != "true" ]; then
        echo "  ❌ Cloudflare token එක වලංගු නෑ."; return 1
    fi

    # account id (token එකට account කීපයක් නම් අහනවා)
    local acct="${CLOUDFLARE_ACCOUNT_ID:-}" lst n
    if [ -z "$acct" ]; then
        lst="$(cf_api "accounts" 2>/dev/null | jq -r '.result[]? | "\(.id) \(.name)"' || true)"
        n="$(printf '%s' "$lst" | grep -c . || true)"
        if [ "$n" -eq 1 ]; then
            acct="${lst%% *}"
        elif [ "$n" -gt 1 ]; then
            echo "$lst" | sed 's/^/     /'
            read -r -p "  Account ID (උඩින් එකක්): " acct
        fi
    fi

    # hostname එකේ zone එක ඔයාගේ account එකේ තියෙනවද
    local z="$cdn_host" found="" r
    while [[ "$z" == *.* ]]; do
        z="${z#*.}"
        r="$(cf_api "zones?name=$z" 2>/dev/null | jq -r '.result | length' 2>/dev/null || echo "")"
        if [ -n "$r" ] && [ "$r" != "null" ] && [ "$r" -gt 0 ] 2>/dev/null; then found="$z"; break; fi
    done
    if [ -n "$found" ]; then
        echo "  ✅ Zone: $found (Cloudflare)"
    else
        echo "  ⚠ $cdn_host සඳහා zone එක Cloudflare account එකේ හොයාගන්න බැරි වුණා (token එකට Zone:Read නැතුව වෙන්නත් පුළුවන්)."
        echo "    Domain එක Cloudflare එකේ add කරලා නැත්නම් custom domain එක වැඩ කරන්නේ නෑ."
    fi

    ensure_node || return 1

    # ── wrangler project (.env එකෙන් generate වෙනවා, ඒ නිසා කවදාවත් වෙනස් වෙන්නේ නෑ) ──
    mkdir -p "$CDN_DIR"
    cp -f "$js" "$CDN_DIR/cdn_worker.js"
    cat > "$CDN_DIR/wrangler.toml" <<EOF
name = "$WORKER_NAME"
main = "cdn_worker.js"
compatibility_date = "2024-11-01"
routes = [{ pattern = "$cdn_host", custom_domain = true }]

[vars]
B2_BUCKET = "$(get_env B2_BUCKET)"
B2_HOST = "$b2_host"
B2_REGION = "$b2_region"
ALLOWED_ORIGINS = "https://$(get_env DOMAIN)"
EOF
    echo "  → wrangler deploy ($WORKER_NAME -> $cdn_host)"
    if ! ( cd "$CDN_DIR" && export CLOUDFLARE_API_TOKEN="$CF_TOKEN" CI=true WRANGLER_SEND_METRICS=false \
             ${acct:+CLOUDFLARE_ACCOUNT_ID="$acct"} && npx --yes wrangler@4 deploy ); then
        echo "  ❌ wrangler deploy fail. Token permissions (Workers Scripts:Edit, Zone:DNS:Edit) බලන්න."
        return 1
    fi

    # ── secrets (Worker එක කියවන්නේ bot එකේ .env එකේ එකම STREAM_SECRET එක) ──
    # Worker එකට වෙනම read-only B2 key එකක් දෙන්න ඕනේ නම් .env එකට B2_READ_KEY_ID / B2_READ_APP_KEY දාන්න.
    local sf rk ra
    rk="$(get_env B2_READ_KEY_ID)";  rk="${rk:-$(get_env B2_KEY_ID)}"
    ra="$(get_env B2_READ_APP_KEY)"; ra="${ra:-$(get_env B2_APP_KEY)}"
    sf="$(mktemp)"; chmod 600 "$sf"
    jq -n --arg a "$(get_env STREAM_SECRET)" --arg b "$rk" --arg c "$ra" \
        '{STREAM_SECRET:$a, B2_KEY_ID:$b, B2_APP_KEY:$c}' > "$sf"
    echo "  → Worker secrets upload"
    if ! ( cd "$CDN_DIR" && export CLOUDFLARE_API_TOKEN="$CF_TOKEN" CI=true WRANGLER_SEND_METRICS=false \
             ${acct:+CLOUDFLARE_ACCOUNT_ID="$acct"} && npx --yes wrangler@4 secret bulk "$sf" ); then
        rm -f "$sf"; echo "  ❌ secrets upload fail."; return 1
    fi
    rm -f "$sf"
    CF_TOKEN=""

    verify_cdn || return 1
    return 0
}

print_cdn_summary() {   # $1 = deploy_cdn_worker return code
    echo " 🎞 Tiered storage patch : $([ "$TIERED_OK" -eq 1 ] || grep -q 'tiered.cdn_url(' "$WORK_DIR/stream_bot.py" 2>/dev/null && echo 'applied' || echo '❌ NOT applied (player එකට CDN source එන්නේ නෑ)')"
    case "$1" in
        0) echo " ☁️ CDN Worker           : ✅ $(get_env CDN_BASE_URL) (end-to-end tested)" ;;
        2) echo " ☁️ CDN Worker           : ⏭ skipped (Menu 6 එකෙන් පස්සේ deploy කරන්න)" ;;
        *) echo " ☁️ CDN Worker           : ❌ failed (උඩ පණිවිඩ බලන්න; Menu 6 එකෙන් ආයෙ try කරන්න)" ;;
    esac
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
echo "1. Full Install (Files + Nginx + SSL + CDN)"
echo "2. Update Files (Keep DB, Subs, Sessions & .env)"
echo "3. Update Config (.env) & Restart"
echo "4. Uninstall"
echo "5. Check Status & Logs"
echo "6. Deploy / Fix Cloudflare CDN Worker"
echo "7. Exit"
echo ""
read -r -p "Choose an option (1-7): " MAIN_OPT

# =====================================================================
# 1 & 2 - INSTALL / UPDATE
# =====================================================================
if [ "$MAIN_OPT" == "1" ] || [ "$MAIN_OPT" == "2" ]; then

    echo "[1/8] Installing system dependencies..."
    ensure_swap
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends python3 python3-pip python3-venv python3-dev build-essential \
        nginx certbot python3-certbot-nginx unzip curl jq rsync sqlite3 openssl ffmpeg dnsutils ca-certificates

    echo "[2/8] Downloading latest release..."
    mkdir -p "$WORK_DIR"
    fetch_files

    echo "[3/8] Configuring environment (.env)..."
    if [ ! -f "$ENV_FILE" ]; then
        configure_env
    else
        echo "  ℹ️ Existing .env found. Keeping it."
        sed -i 's/\r$//' "$ENV_FILE"
        if [ -z "$(get_env STREAM_SECRET)" ]; then set_env STREAM_SECRET "$(openssl rand -hex 32)"; fi
        if [ -z "$(get_env DOMAIN)" ]; then set_env DOMAIN "$DEFAULT_DOMAIN"; fi
        if [ -z "$(get_env PUBLIC_BASE_URL)" ]; then set_env PUBLIC_BASE_URL "https://$(get_env DOMAIN)"; fi
        if [ -z "$(get_env PORT)" ]; then set_env PORT "$APP_PORT"; fi
        check_cdn_host
    fi
    APP_PORT="$(get_env PORT)"; APP_PORT="${APP_PORT:-8080}"
    DOMAIN_VAL="$(get_env DOMAIN)"; DOMAIN_VAL="${DOMAIN_VAL:-$DEFAULT_DOMAIN}"

    echo "[4/8] Installing Python packages..."
    install_python

    echo "[5/8] Applying files & permissions..."
    write_service
    apply_files

    echo "[6/8] Starting $SERVICE_NAME..."
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
        echo "[7/8] Setting up Nginx + SSL for $DOMAIN_VAL ..."
        echo "  ℹ️ Cloudflare Proxy (orange cloud) නම් SSL mode = Full / Full (strict)."
        setup_nginx_ssl "$DOMAIN_VAL"
    else
        echo "[7/8] Nginx unchanged (update mode)."
    fi

    echo "[8/8] Cloudflare CDN Worker (B2 hot tier)..."
    CDN_RC=0
    if [ -n "$(get_env B2_BUCKET)" ] && [ -n "$(get_env CDN_BASE_URL)" ]; then
        deploy_cdn_worker || CDN_RC=$?
    else
        echo "  ℹ️ B2_BUCKET / CDN_BASE_URL .env හි නෑ -> skip (Menu 3 එකෙන් දාලා Menu 6 run කරන්න)."
        CDN_RC=2
    fi
    if [ "$CDN_ENV_CHANGED" -eq 1 ]; then
        systemctl restart "$SERVICE_NAME"
        echo "  🔄 CDN_BASE_URL වෙනස් වුණු නිසා $SERVICE_NAME restart කළා."
    fi

    echo ""
    echo "================================================"
    echo " ✅ DEPLOYMENT COMPLETE!  ($REL_TAG)"
    echo " 🌐 URL : https://$DOMAIN_VAL"
    print_cdn_summary "$CDN_RC"
    echo " 📜 Logs: journalctl -u $SERVICE_NAME -f"
    echo "================================================"

# =====================================================================
# 3 - UPDATE ENV ONLY
# =====================================================================
elif [ "$MAIN_OPT" == "3" ]; then
    configure_env
    patch_bot
    patch_tiered
    fix_permissions
    systemctl restart "$SERVICE_NAME"
    echo "✅ .env updated and service restarted."
    echo "   CDN URL / B2 keys / STREAM_SECRET වෙනස් කළා නම් Menu 6 එකෙන් Worker එකත් update කරන්න."

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
    echo "   Cloudflare Worker ($WORKER_NAME) ඉවත් කරන්න: cd $CDN_DIR && npx wrangler delete"

# =====================================================================
# 5 - STATUS
# =====================================================================
elif [ "$MAIN_OPT" == "5" ]; then
    systemctl status "$SERVICE_NAME" --no-pager || true
    systemctl status nginx --no-pager | head -n 5 || true
    certbot certificates 2>/dev/null | grep -E "Domains|Expiry" || true
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true

# =====================================================================
# 6 - CDN WORKER ONLY  (patch + worker deploy + end-to-end test)
# =====================================================================
elif [ "$MAIN_OPT" == "6" ]; then
    if [ ! -f "$ENV_FILE" ]; then echo "❌ $ENV_FILE නෑ. මුලින් Option 1 run කරන්න."; exit 1; fi
    sed -i 's/\r$//' "$ENV_FILE"
    APP_PORT="$(get_env PORT)"; APP_PORT="${APP_PORT:-8080}"
    patch_tiered
    fix_permissions
    CDN_RC=0
    deploy_cdn_worker || CDN_RC=$?
    systemctl restart "$SERVICE_NAME"     # patch / CDN_BASE_URL වෙනස්කම් load වෙන්න
    echo ""
    echo "================================================"
    print_cdn_summary "$CDN_RC"
    echo "================================================"
else
    exit 0
fi

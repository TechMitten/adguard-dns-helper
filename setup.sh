#!/bin/bash

set -euo pipefail

GITHUB_REPO="AdguardTeam/AdGuardDNSCLI"
BINARY_NAME="adguarddns-cli"
SERVICE_NAME="adguarddns-cli"

INSTALL_DIR="/opt/adguard-cli"
BINARY_PATH="${INSTALL_DIR}/${BINARY_NAME}"
CONFIG_FILE="${INSTALL_DIR}/config.yaml"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
LOG_FILE="/var/log/adguarddns-setup.log"

RESOLV="/etc/resolv.conf"
RESOLV_BAK="/etc/resolv.conf.bak"

TEMP_DIR=""
cleanup() { if [ -n "$TEMP_DIR" ]; then rm -rf "$TEMP_DIR"; fi; }
trap cleanup EXIT

die() { echo "❌ $*" >&2; exit 1; }

# --- Helpers ---

# True if the given resolv.conf-style file lists 127.0.0.1 as a nameserver.
resolv_points_local() {
    grep -Eq '^[[:space:]]*nameserver[[:space:]]+127\.0\.0\.1[[:space:]]*$' "$1" 2>/dev/null
}

# Put a known-good resolv.conf back: the backup if it's usable,
# otherwise temporary public resolvers.
restore_system_dns() {
    chattr -i "$RESOLV" 2>/dev/null || true
    rm -f "$RESOLV"
    if { [ -e "$RESOLV_BAK" ] || [ -L "$RESOLV_BAK" ]; } && ! resolv_points_local "$RESOLV_BAK"; then
        cp -a "$RESOLV_BAK" "$RESOLV"
    fi
    # The backup may be a symlink to systemd-resolved's stub file, which is
    # dead if resolved was disabled. If DNS doesn't work, use public resolvers.
    if [ ! -e "$RESOLV" ] || ! getent hosts github.com >/dev/null 2>&1; then
        rm -f "$RESOLV"
        printf 'nameserver 9.9.9.9\nnameserver 1.1.1.1\n' > "$RESOLV"
    fi
}

# Query the local AdGuard instance directly (not via the system resolver).
dns_ok() {
    if command -v dig >/dev/null; then
        dig +short +time=3 +tries=1 @127.0.0.1 example.com A 2>/dev/null | grep -Eq '^[0-9]+\.'
    else
        nslookup -timeout=3 example.com 127.0.0.1 2>/dev/null \
            | awk '/^Name:/{f=1} f && /^Address/{found=1} END{exit !found}'
    fi
}

# True if something OTHER than a previous install of this tool is listening on
# port 53 on localhost/wildcard. Our own old service is ignored here because
# the cleanup step will stop it. (Needs root to see process names.)
port53_busy() {
    command -v ss >/dev/null || return 1
    ss -H -lntup 2>/dev/null | awk '
        $5 ~ /^(127\.0\.0\.1|0\.0\.0\.0|\*|\[::\]):53$/ && $0 !~ /"adguarddns-cli"/ { found = 1 }
        END { exit !found }'
}

# Yes/no prompt, default No.
ask_yes_no() {
    local ans=""
    read -rp "$1 [y/N]: " ans || true
    case "${ans,,}" in y|yes) return 0 ;; *) return 1 ;; esac
}

# Write the COMPLETE official config schema from the current settings.
write_config() {
    install -m 600 /dev/null "$CONFIG_FILE"
    cat > "$CONFIG_FILE" <<EOF
schema_version: 4
dns:
  cache:
    enabled: true
    size: 128MB
    client_size: 4MB
  server:
    bind_retry:
      enabled: true
      interval: 1s
      count: 4
    listen_addresses:
      - address: '127.0.0.1:53'
    pending_requests:
      enabled: true
  bootstrap:
    servers:
      - address: '${BOOT_1}'
      - address: '${BOOT_2}'
    timeout: 2s
  upstream:
    groups:
      'default':
        address: '${UPSTREAM_ADDRESS}'
        autodevice:
          enabled: false
    timeout: 2s
${FALLBACK_BLOCK}
debug:
  pprof:
    port: 6060
    enabled: false
log:
  output: 'syslog'
  format: 'default'
  timestamp: false
  verbose: false
EOF
}

# Wait up to 15 seconds for the local AdGuard instance to answer.
wait_for_adguard() {
    for _ in $(seq 1 15); do
        sleep 1
        if dns_ok; then return 0; fi
    done
    return 1
}

# --- 1. Pre-flight checks ---
[ "$EUID" -eq 0 ] || die "This script must be run as root (sudo ./setup-adguard.sh)."
command -v curl      >/dev/null || die "'curl' is not installed."
command -v tar       >/dev/null || die "'tar' is not installed."
command -v getent    >/dev/null || die "'getent' is not installed."
command -v systemctl >/dev/null || die "systemd is required."
if ! command -v dig >/dev/null && ! command -v nslookup >/dev/null; then
    die "Neither 'dig' nor 'nslookup' is installed (needed to test the resolver). Install dnsutils / bind-utils and re-run."
fi

# Fail fast, before anything is touched: make sure nothing else holds port 53.
# (A previous install of this tool is fine; it gets replaced further down.)
if port53_busy; then
    die "Something else is already listening on port 53 (check: ss -lntup | grep ':53 '). Stop it and re-run. Nothing was changed."
fi

: > "$LOG_FILE"; chmod 600 "$LOG_FILE"

# --- 2. Choose protocol ---
echo "======================================================"
echo "   AdGuard DNS CLI Setup"
echo "======================================================"
echo
echo "Choose which DNS protocol to use:"
echo "  1) DNS-over-HTTPS (DoH)"
echo "  2) DNS-over-TLS (DoT)"
echo "  3) DNS-over-QUIC (DoQ)"
echo "  4) Plain DNS (unencrypted)"
echo
read -rp "Enter your choice (1-4): " PROTOCOL_CHOICE

case "$PROTOCOL_CHOICE" in
    1) PROTOCOL_NAME="DoH";       URL_SCHEME="https://"; DEFAULT_URL="https://dns.adguard-dns.com/dns-query" ;;
    2) PROTOCOL_NAME="DoT";       URL_SCHEME="tls://";   DEFAULT_URL="tls://dns.adguard-dns.com" ;;
    3) PROTOCOL_NAME="DoQ";       URL_SCHEME="quic://";  DEFAULT_URL="quic://dns.adguard-dns.com" ;;
    4) PROTOCOL_NAME="Plain DNS"; URL_SCHEME="";         DEFAULT_URL="94.140.14.14:53" ;;
    *) die "Invalid choice." ;;
esac

echo
echo "You chose: $PROTOCOL_NAME"
echo "Press Enter to use AdGuard's public server, or paste your private URL."
read -rp "URL (or Enter for default): " USER_URL

USER_URL="${USER_URL//[[:space:]]/}"
UPSTREAM_ADDRESS="${USER_URL:-$DEFAULT_URL}"

# Offer AdGuard's public IP address instead of its hostname. An IP upstream
# needs no hostname lookup, so no bootstrap DNS traffic is ever sent.
if [ -z "$USER_URL" ] && [ "$PROTOCOL_CHOICE" != "4" ]; then
    echo
    echo "AdGuard's public server can be used by IP address (94.140.14.14) instead of"
    echo "by hostname. That avoids any hostname lookup, so nothing is sent as plain DNS."
    echo "Experimental: it only works if the server's certificate covers that IP."
    echo "If it doesn't, the script stops before changing your DNS."
    if ask_yes_no "Use the IP address?"; then
        case "$PROTOCOL_CHOICE" in
            1) UPSTREAM_ADDRESS="https://94.140.14.14/dns-query" ;;
            2) UPSTREAM_ADDRESS="tls://94.140.14.14" ;;
            3) UPSTREAM_ADDRESS="quic://94.140.14.14" ;;
        esac
    fi
fi

if [[ "$UPSTREAM_ADDRESS" == *"'"* || "$UPSTREAM_ADDRESS" == *'"'* || "$UPSTREAM_ADDRESS" == *'\'* ]]; then
    die "URL contains invalid characters (quotes or backslashes)."
fi

if [ -n "$URL_SCHEME" ] && [[ "$UPSTREAM_ADDRESS" != ${URL_SCHEME}* ]]; then
    die "Your URL should start with '${URL_SCHEME}'."
fi

if [ "$PROTOCOL_CHOICE" = "4" ] && [[ "$UPSTREAM_ADDRESS" != *:* ]]; then
    UPSTREAM_ADDRESS="${UPSTREAM_ADDRESS}:53"
fi

# --- 2b. Choose fallback DNS ---
echo
echo "Fallback DNS is only used if AdGuard can't be reached."
echo "Fallback queries use DNS-over-TLS, so they are encrypted on the wire,"
echo "but the fallback provider can still see them. With 'AdGuard only', no other"
echo "provider is used and lookups simply fail while AdGuard is unreachable."
echo
echo "Choose a fallback:"
echo "  1) AdGuard only (most private; retries AdGuard, DNS fails if it's down)"
echo "  2) Cloudflare (1.1.1.1, 1.0.0.1)"
echo "  3) Google     (8.8.8.8, 8.8.4.4)"
echo "  4) Quad9      (9.9.9.9, 149.112.112.112)"
echo
read -rp "Enter your choice (1-4) [1]: " FALLBACK_CHOICE
FALLBACK_CHOICE="${FALLBACK_CHOICE:-1}"

FALLBACK_NAME="AdGuard only"
FALLBACK_1=""
FALLBACK_2=""
case "$FALLBACK_CHOICE" in
    # The CLI requires at least one fallback server ("dns: fallback: no value"),
    # so "AdGuard only" falls back to the AdGuard upstream itself: no third party.
    1) FALLBACK_1="$UPSTREAM_ADDRESS" ;;
    2) FALLBACK_NAME="Cloudflare"; FALLBACK_1="tls://1.1.1.1"; FALLBACK_2="tls://1.0.0.1" ;;
    3) FALLBACK_NAME="Google";     FALLBACK_1="tls://8.8.8.8"; FALLBACK_2="tls://8.8.4.4" ;;
    4) FALLBACK_NAME="Quad9";      FALLBACK_1="tls://9.9.9.9"; FALLBACK_2="tls://149.112.112.112" ;;
    *) die "Invalid fallback choice." ;;
esac

# Build the YAML block (already indented to sit under 'dns:').
FALLBACK_BLOCK="  fallback:
    servers:
      - address: '${FALLBACK_1}'"
if [ -n "$FALLBACK_2" ]; then
    FALLBACK_BLOCK="${FALLBACK_BLOCK}
      - address: '${FALLBACK_2}'"
fi
FALLBACK_BLOCK="${FALLBACK_BLOCK}
    timeout: 2s"

# --- 2c. Choose bootstrap DNS ---
# Bootstrap servers are only used to look up the IP of the upstream's hostname.
UPSTREAM_HOST="${UPSTREAM_ADDRESS#*://}"
UPSTREAM_HOST="${UPSTREAM_HOST%%/*}"
UPSTREAM_HOST="${UPSTREAM_HOST%%:*}"
IPV4_RE='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
UPSTREAM_IS_IP=false
if [[ "$UPSTREAM_HOST" =~ $IPV4_RE || "$UPSTREAM_HOST" == \[* ]]; then
    UPSTREAM_IS_IP=true
fi

# Same servers as the official config template. The CLI only accepts plain
# IP:port bootstrap servers (tls:// ones fail with "invalid port").
BOOT_1="8.8.8.8:53"
BOOT_2="8.8.4.4:53"
if [ "$UPSTREAM_IS_IP" = true ]; then
    BOOTSTRAP_NAME="not needed (upstream is an IP address)"
else
    BOOTSTRAP_NAME="Google (8.8.8.8, 8.8.4.4)"
fi

echo
echo "🚀 Setting up with $PROTOCOL_NAME"
echo "   Upstream: $UPSTREAM_ADDRESS"
echo "   Fallback: $FALLBACK_NAME"
echo "   Bootstrap: $BOOTSTRAP_NAME"

# --- 3. Make sure the system has working DNS before we start ---
# If a previous run switched resolv.conf to 127.0.0.1, the tear-down below
# would leave nothing answering there. Restore the original DNS first so the
# download works and a failed re-run can't strand the machine without DNS.
if resolv_points_local "$RESOLV"; then
    echo "🔁 $RESOLV already points at 127.0.0.1 (previous install?)."
    echo "   Restoring original DNS temporarily so this run can't leave you without DNS..."
    restore_system_dns
fi

# --- 4. Download (BEFORE touching the existing install) ---
case "$(uname -m)" in
    x86_64|amd64)  ARCH_SUFFIX="amd64" ;;
    aarch64|arm64) ARCH_SUFFIX="arm64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
esac

echo "🔍 Finding the latest release..."
API_JSON=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest") \
    || die "Could not reach the GitHub API."

RELEASE_URL=$(printf '%s\n' "$API_JSON" | grep "browser_download_url" \
    | grep "linux_${ARCH_SUFFIX}.tar.gz" | cut -d '"' -f 4 | head -n 1 || true)
[ -n "$RELEASE_URL" ] || die "No matching linux_${ARCH_SUFFIX}.tar.gz asset found."
echo "⬇️  Downloading: $RELEASE_URL"
TEMP_DIR=$(mktemp -d)
curl -fsSL "$RELEASE_URL" -o "$TEMP_DIR/pkg.tar.gz" || die "Download failed."

tar -xzf "$TEMP_DIR/pkg.tar.gz" -C "$TEMP_DIR" || die "Extraction failed."

BINARY_FILE=$(find "$TEMP_DIR" -maxdepth 3 -type f -name "$BINARY_NAME" | head -n 1 || true)
[ -n "$BINARY_FILE" ] || die "Could not find '$BINARY_NAME' in the archive."

# --- 5. Clean up ANY previous install ---
echo "🧹 Cleaning up any previous AdGuard DNS CLI installs..."

systemctl stop    "$SERVICE_NAME"        2>/dev/null || true
systemctl stop    "AdGuardDNSCLI"        2>/dev/null || true
systemctl disable "$SERVICE_NAME"        2>/dev/null || true
systemctl disable "AdGuardDNSCLI"        2>/dev/null || true

rm -f "$SERVICE_PATH"
rm -f "/etc/systemd/system/AdGuardDNSCLI.service"
rm -f "/etc/systemd/system/multi-user.target.wants/${SERVICE_NAME}.service"
rm -f "/etc/systemd/system/multi-user.target.wants/AdGuardDNSCLI.service"

rm -rf "$INSTALL_DIR"

systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

# --- 6. Install binary ---
mkdir -p "$INSTALL_DIR"
mv "$BINARY_FILE" "$BINARY_PATH"
chmod 755 "$BINARY_PATH"

# --- 7. Write the COMPLETE official config schema ---
echo "📝 Writing config to $CONFIG_FILE"

write_config

# --- 8. Write the systemd unit directly (avoid the buggy official installer) ---
echo "⚙️  Writing systemd unit..."

cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=AdGuard DNS CLI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BINARY_PATH}
Restart=always
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >>"$LOG_FILE" 2>&1 || true
systemctl restart "$SERVICE_NAME" >>"$LOG_FILE" 2>&1 || true

# --- 9. Verify AdGuard answers BEFORE touching system DNS ---
echo "🔎 Waiting for AdGuard to answer on 127.0.0.1..."
ANSWERING=false
if wait_for_adguard; then
    ANSWERING=true
fi

if [ "$ANSWERING" != true ]; then
    echo "❌ AdGuard is not answering on 127.0.0.1. System DNS was NOT changed." >&2
    echo "" >&2
    echo "---- Diagnostic info ----" >&2
    echo "Service status:" >&2
    systemctl status "$SERVICE_NAME" --no-pager -n 10 >&2 || true
    echo "" >&2
    echo "Last 20 journal lines (review before sharing; may include your upstream URL):" >&2
    journalctl -u "$SERVICE_NAME" -n 20 --no-pager >&2 || true
    echo "" >&2
    echo "Config file: $CONFIG_FILE (not printed, it may contain a private device ID)" >&2
    echo "Setup log:   $LOG_FILE" >&2
    if [ "$UPSTREAM_IS_IP" = true ] && [ "$PROTOCOL_CHOICE" != "4" ]; then
        echo "" >&2
        echo "You used an IP-address upstream. Its certificate may not cover that IP;" >&2
        echo "re-run and answer 'n' to use the hostname instead." >&2
    fi
    # Don't leave a broken service restarting every few seconds.
    systemctl disable --now "$SERVICE_NAME" >>"$LOG_FILE" 2>&1 || true
    echo "" >&2
    echo "The $SERVICE_NAME service was stopped and disabled." >&2
    exit 1
fi
echo "✅ AdGuard is answering on 127.0.0.1."

# --- 10. Switch system DNS (safely, with backup) ---
echo "🔧 Pointing system DNS at AdGuard..."

chattr -i "$RESOLV" 2>/dev/null || true

# Only back up a resolv.conf that is NOT already pointing at us.
if { [ -e "$RESOLV" ] || [ -L "$RESOLV" ]; } && ! resolv_points_local "$RESOLV"; then
    [ -e "$RESOLV_BAK" ] || [ -L "$RESOLV_BAK" ] || cp -a "$RESOLV" "$RESOLV_BAK"
fi

rm -f "$RESOLV"
printf 'nameserver 127.0.0.1\n' > "$RESOLV"

# --- 11. Final check + auto-rollback ---
sleep 1
if getent hosts www.example.com >/dev/null; then
    echo "✅ System resolver works:"
    getent hosts www.example.com
else
    echo "❌ System resolution failed after switch. Rolling back..." >&2
    restore_system_dns
    exit 1
fi


# --- 12. Optional: stop other tools from rewriting resolv.conf later ---
RESOLVED_DISABLED=false
NM_CONFIGURED=false

if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    echo
    echo "systemd-resolved is running. It usually leaves a regular $RESOLV alone,"
    echo "but some setups re-create its link to it, which would silently undo this change."
    echo "Disabling it prevents that, but VPNs or tools that rely on its per-interface DNS"
    echo "may stop working."
    if ask_yes_no "Disable systemd-resolved now?"; then
        systemctl disable --now systemd-resolved >>"$LOG_FILE" 2>&1 || true
        sleep 1
        if getent hosts www.example.com >/dev/null; then
            RESOLVED_DISABLED=true
            echo "✅ systemd-resolved disabled; DNS still works through AdGuard."
        else
            echo "❌ DNS failed after disabling systemd-resolved. Re-enabling it and rolling back..." >&2
            systemctl enable --now systemd-resolved >>"$LOG_FILE" 2>&1 || true
            sleep 2
            restore_system_dns
            exit 1
        fi
    fi
fi

if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    echo
    echo "NetworkManager is running and may rewrite $RESOLV when the network reconnects."
    echo "Setting 'dns=none' only stops it editing that file; your networking is not affected."
    if ask_yes_no "Tell NetworkManager to leave DNS settings alone?"; then
        mkdir -p /etc/NetworkManager/conf.d
        printf '[main]\ndns=none\n' > /etc/NetworkManager/conf.d/90-adguard-dns.conf
        systemctl reload NetworkManager >>"$LOG_FILE" 2>&1 || true
        NM_CONFIGURED=true
        echo "✅ Written to /etc/NetworkManager/conf.d/90-adguard-dns.conf"
    fi
fi

echo
echo "🎉 Done. AdGuard DNS CLI is running with $PROTOCOL_NAME (fallback: $FALLBACK_NAME, bootstrap: $BOOTSTRAP_NAME)."
echo "   Status:        systemctl status $SERVICE_NAME"
echo "   Setup log:     $LOG_FILE"
echo "   To undo DNS:   sudo rm /etc/resolv.conf && sudo cp -a /etc/resolv.conf.bak /etc/resolv.conf"
if [ "$RESOLVED_DISABLED" = true ]; then
    echo "                  then: sudo systemctl enable --now systemd-resolved"
fi
if [ "$NM_CONFIGURED" = true ]; then
    echo "                  and:  sudo rm /etc/NetworkManager/conf.d/90-adguard-dns.conf && sudo systemctl reload NetworkManager"
fi

#!/usr/bin/env bash
set -euo pipefail

# --- Defaults (can be overridden via env) ---
DEFAULT_LOKI_IP="${DEFAULT_LOKI_IP:-10.0.2.35}"
PROMTAIL_CONFIG="/etc/promtail/config.yml"
POS_DIR="/var/lib/promtail"
POS_FILE="${POS_DIR}/positions.yml"
# --------------------------------------------

log() { printf "\033[1;32m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!!\033[0m %s\n" "$*"; }
die() { printf "\033[1;31mXX\033[0m %s\n" "$*"; exit 1; }

# A) Detect OS (Debian/Ubuntu expected)
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VER="${VERSION_ID:-unknown}"
  log "Detected ${OS_ID^} ${OS_VER}"
else
  die "Cannot detect OS (missing /etc/os-release)."
fi

# B) Ask user inputs
APP_NAME="${APP_NAME:-}"
if [[ -z "${APP_NAME}" ]]; then
  read -rp "Application name for this LXC (e.g. jellyfin, radarr): " APP_NAME
fi
[[ -z "${APP_NAME}" ]] && die "Application name is required."

read -rp "Loki IP or URL [${DEFAULT_LOKI_IP}]: " LOKI_INPUT
LOKI_INPUT="${LOKI_INPUT:-$DEFAULT_LOKI_IP}"
if [[ "${LOKI_INPUT}" =~ ^https?:// ]]; then
  LOKI_URL="${LOKI_INPUT%/}/loki/api/v1/push"
else
  LOKI_URL="http://${LOKI_INPUT}:3100/loki/api/v1/push"
fi
log "Using Loki push URL: ${LOKI_URL}"

SERVICE_NAME="${SERVICE_NAME:-${APP_NAME}.service}"

# Basic deps + Promtail
log "Installing prerequisites and Promtail…"
apt-get update
apt-get install -y curl gpg ca-certificates
mkdir -p /etc/apt/keyrings
[[ -s /etc/apt/keyrings/grafana.gpg ]] || curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
[[ -s /etc/apt/sources.list.d/grafana.list ]] || echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update
apt-get install -y promtail

# C) Make the app write to journald
log "Configuring systemd override for ${SERVICE_NAME} → journald…"
OVR_DIR="/etc/systemd/system/${SERVICE_NAME%.service}.service.d"
mkdir -p "$OVR_DIR"
cat > "${OVR_DIR}/override.conf" <<EOF
[Service]
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${APP_NAME}
EOF
systemctl daemon-reload
if systemctl status "${SERVICE_NAME}" >/dev/null 2>&1; then
  systemctl restart "${SERVICE_NAME}" || warn "Restart of ${SERVICE_NAME} failed. Check the unit name."
else
  warn "Service ${SERVICE_NAME} not found. Skipping restart; verify the correct unit name."
fi

# Ensure persistent journal in LXC
log "Ensuring persistent journald…"
mkdir -p /var/log/journal
systemctl restart systemd-journald

# D/E) Promtail positions, perms, config (host label = app name)
log "Preparing Promtail state and permissions…"
mkdir -p "${POS_DIR}"
touch "${POS_FILE}"
chown -R promtail: "${POS_DIR}"
chmod 755 "${POS_DIR}"
chmod 640 "${POS_FILE}"
usermod -aG systemd-journal promtail || true
usermod -aG adm promtail || true

log "Writing ${PROMTAIL_CONFIG}…"
mkdir -p "$(dirname "${PROMTAIL_CONFIG}")"
cat > "${PROMTAIL_CONFIG}" <<YAML
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: ${POS_FILE}

clients:
  - url: ${LOKI_URL}
    batchwait: 1s
    batchsize: 1048576

scrape_configs:
  # Journald from this LXC
  - job_name: journal
    journal:
      path: /var/log/journal
      max_age: 24h
      labels:
        host: ${APP_NAME}
        job: systemd
    relabel_configs:
      - source_labels: ['__journal__systemd_unit']
        target_label: unit
      - source_labels: ['__journal__syslog_identifier']
        target_label: app

  # Generic files under /var/log (covers nginx, many services)
  - job_name: varlogs
    static_configs:
      - targets: ['localhost']
        labels:
          host: ${APP_NAME}
          job: varlogs
          __path__: /var/log/**/*.log
YAML

# F) Enable, verify, hint
log "Enabling and starting Promtail…"
systemctl enable --now promtail

if command -v promtail >/dev/null 2>&1; then
  if promtail -config.file "${PROMTAIL_CONFIG}" -verify-config >/dev/null 2>&1; then
    log "Promtail config verification: OK"
  else
    warn "Promtail config verification reported issues (continuing)."
  fi
fi

journalctl -u promtail -n 30 --no-pager || true
log "Done. Query in Grafana → Explore (Loki): {job=\"systemd\",host=\"${APP_NAME}\"}"

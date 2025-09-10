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

# Detect OS (Debian/Ubuntu expected)
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  log "Detected ${ID^} ${VERSION_ID:-unknown}"
else
  die "Cannot detect OS (missing /etc/os-release)."
fi

# --- Input: app name & Loki address ---
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

# --- Service resolution helper ---
normalise_unit() {
  # ensure .service suffix
  local u="$1"
  [[ "$u" == *.service ]] || u="${u}.service"
  printf "%s" "$u"
}

pick_service() {
  local hint="${1:-}" ; local -a cands=() ; local line
  # collect active/inactive units that match (case-insensitive)
  while read -r line; do cands+=("${line%% *}"); done < <(systemctl list-units --type=service --all --no-legend --no-pager | grep -i "${hint}" || true)
  # collect installed unit files too
  while read -r line; do cands+=("${line%% *}"); done < <(systemctl list-unit-files --type=service --no-legend --no-pager | grep -i "${hint}" || true)
  # add common guesses
  cands+=("$(normalise_unit "${hint}")" "$(normalise_unit "${hint,,}")")

  # uniq, drop empties
  mapfile -t cands < <(printf "%s\n" "${cands[@]}" | awk 'NF' | sort -fu)

  if (( ${#cands[@]} == 0 )); then
    warn "No services matched '${hint}'. You can re-run with SERVICE_NAME=<unit>.service"
    return 1
  elif (( ${#cands[@]} == 1 )); then
    printf "%s" "${cands[0]}"
    return 0
  else
    log "Multiple services matched '${hint}':"
    local i=1
    for s in "${cands[@]}"; do printf "  [%d] %s\n" "$i" "$s"; ((i++)); done
    read -rp "Select [1]: " choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#cands[@]} )); then
      printf "%s" "${cands[choice-1]}"
      return 0
    else
      printf "%s" "${cands[0]}"
      return 0
    fi
  fi
}

# Resolve service (allow override)
SERVICE_NAME="${SERVICE_NAME:-}"
if [[ -z "${SERVICE_NAME}" ]]; then
  if ! SERVICE_NAME="$(pick_service "${APP_NAME}")"; then
    warn "Skipping journald override (service not found)."
    SERVICE_NAME=""
  fi
fi
if [[ -n "${SERVICE_NAME}" ]]; then
  SERVICE_NAME="$(normalise_unit "${SERVICE_NAME}")"
  log "Using service: ${SERVICE_NAME}"
fi

# --- Install Promtail ---
log "Installing prerequisites and Promtail…"
apt-get update
apt-get install -y curl gpg ca-certificates
mkdir -p /etc/apt/keyrings
[[ -s /etc/apt/keyrings/grafana.gpg ]] || curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
[[ -s /etc/apt/sources.list.d/grafana.list ]] || echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update
apt-get install -y promtail

# --- Journald override for the service (if resolved) ---
if [[ -n "${SERVICE_NAME}" ]]; then
  log "Configuring systemd override for ${SERVICE_NAME} → journald…"
  OVR_DIR="/etc/systemd/system/${SERVICE_NAME}.d"
  mkdir -p "$OVR_DIR"
  cat > "${OVR_DIR}/override.conf" <<EOF
[Service]
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${APP_NAME}
EOF
  systemctl daemon-reload
  if systemctl status "${SERVICE_NAME}" >/dev/null 2>&1; then
    systemctl restart "${SERVICE_NAME}" || warn "Restart of ${SERVICE_NAME} failed. Check the unit."
  else
    warn "Service ${SERVICE_NAME} not running; override installed."
  fi
fi

# --- Ensure persistent journal & promtail state ---
log "Ensuring persistent journald and promtail state…"
mkdir -p /var/log/journal
systemctl restart systemd-journald || true

mkdir -p "${POS_DIR}"
touch "${POS_FILE}"
chown -R promtail: "${POS_DIR}"
chmod 755 "${POS_DIR}"
chmod 640 "${POS_FILE}"

# journal + /var/log access
usermod -aG systemd-journal promtail || true
usermod -aG adm promtail || true

# --- Promtail config ---
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

  - job_name: varlogs
    static_configs:
      - targets: ['localhost']
        labels:
          host: ${APP_NAME}
          job: varlogs
          __path__: /var/log/**/*.log
YAML

# --- Start & verify ---
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

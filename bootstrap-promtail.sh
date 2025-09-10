#!/usr/bin/env bash
set -euo pipefail

# Defaults (override via env)
DEFAULT_LOKI_IP="${DEFAULT_LOKI_IP:-10.0.2.35}"
PROMTAIL_CONFIG="/etc/promtail/config.yml"
POS_DIR="/var/lib/promtail"
POS_FILE="${POS_DIR}/positions.yml"

log()  { >&2 printf "\033[1;32m==>\033[0m %s\n" "$*"; }
warn() { >&2 printf "\033[1;33m!!\033[0m %s\n" "$*"; }
die()  { >&2 printf "\033[1;31mXX\033[0m %s\n" "$*"; exit 1; }

read_tty() {
  local prompt="$1" var=""
  if [[ -t 0 ]]; then
    read -rp "$prompt" var
  else
    # read from the terminal when stdin is a pipe
    read -rp "$prompt" var </dev/tty || true
  fi
  printf "%s" "$var"
}

# Detect OS
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  log "Detected ${ID^} ${VERSION_ID:-unknown}"
else
  die "Cannot detect OS (missing /etc/os-release)."
fi

# Inputs
APP_NAME="${APP_NAME:-}"
[[ -z "$APP_NAME" ]] && APP_NAME="$(read_tty 'Application name for this LXC (e.g. jellyfin, radarr): ')"
[[ -z "$APP_NAME" ]] && die "Application name is required."

LOKI_INPUT="$(read_tty "Loki IP or URL [${DEFAULT_LOKI_IP}]: ")"
LOKI_INPUT="${LOKI_INPUT:-$DEFAULT_LOKI_IP}"
if [[ "$LOKI_INPUT" =~ ^https?:// ]]; then
  LOKI_URL="${LOKI_INPUT%/}/loki/api/v1/push"
else
  LOKI_URL="http://${LOKI_INPUT}:3100/loki/api/v1/push"
fi
log "Using Loki push URL: ${LOKI_URL}"

# Service resolution
normalise_unit() { [[ "$1" == *.service ]] && printf %s "$1" || printf %s "$1.service"; }

pick_service() {
  local hint="$1"; local -a cands=(); local line
  while read -r line; do cands+=("${line%% *}"); done < <(systemctl list-units --type=service --all --no-legend --no-pager | grep -i "$hint" || true)
  while read -r line; do cands+=("${line%% *}"); done < <(systemctl list-unit-files --type=service --no-legend --no-pager | grep -i "$hint" || true)
  cands+=("$(normalise_unit "$hint")" "$(normalise_unit "${hint,,}")")
  mapfile -t cands < <(printf "%s\n" "${cands[@]}" | awk 'NF' | sort -fu)

  if ((${#cands[@]}==0)); then
    return 1
  elif ((${#cands[@]}==1)); then
    printf "%s" "${cands[0]}"
  else
    log "Multiple services matched '${hint}':"
    local i=1; for s in "${cands[@]}"; do >&2 printf "  [%d] %s\n" "$i" "$s"; ((i++)); done
    local choice; choice="$(read_tty 'Select [1]: ')"; choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#cands[@]} )); then
      printf "%s" "${cands[choice-1]}"
    else
      printf "%s" "${cands[0]}"
    fi
  fi
}

SERVICE_NAME="${SERVICE_NAME:-}"
if [[ -z "$SERVICE_NAME" ]]; then
  if SERVICE_NAME="$(pick_service "$APP_NAME")"; then
    SERVICE_NAME="$(normalise_unit "$SERVICE_NAME")"
    log "Using service: ${SERVICE_NAME}"
  else
    warn "No systemd unit matched '${APP_NAME}'. Will skip journald override."
    SERVICE_NAME=""
  fi
fi

# Install Promtail
log "Installing prerequisites and Promtail…"
apt-get update
apt-get install -y curl gpg ca-certificates
mkdir -p /etc/apt/keyrings
[[ -s /etc/apt/keyrings/grafana.gpg ]] || curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
[[ -s /etc/apt/sources.list.d/grafana.list ]] || echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update
apt-get install -y promtail

# Journald override (only for the resolved unit)
if [[ -n "$SERVICE_NAME" ]]; then
  log "Configuring journald override for ${SERVICE_NAME}…"
  OVR_DIR="/etc/systemd/system/${SERVICE_NAME}.d"
  mkdir -p "$OVR_DIR"
  cat > "${OVR_DIR}/override.conf" <<EOF
[Service]
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${APP_NAME}
EOF
  systemctl daemon-reload
  if systemctl status "$SERVICE_NAME" >/dev/null 2>&1; then
    systemctl restart "$SERVICE_NAME" || warn "Restart failed, check the unit."
  fi
fi

# Persistent journal & Promtail state
log "Ensuring persistent journald…"
mkdir -p /var/log/journal
systemctl restart systemd-journald || true

log "Preparing promtail state…"
mkdir -p "$POS_DIR"
touch "$POS_FILE"
chown -R promtail: "$POS_DIR"
chmod 755 "$POS_DIR"
chmod 640 "$POS_FILE"
usermod -aG systemd-journal promtail || true
usermod -aG adm promtail || true

# Promtail config
log "Writing ${PROMTAIL_CONFIG}…"
mkdir -p "$(dirname "$PROMTAIL_CONFIG")"
cat > "$PROMTAIL_CONFIG" <<YAML
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: ${POS_FILE}

clients:
  - url: ${L OKI_URL}
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

# Start & verify
log "Enabling and starting promtail…"
systemctl enable --now promtail
if command -v promtail >/dev/null 2>&1; then
  promtail -config.file "$PROMTAIL_CONFIG" -verify-config >/dev/null 2>&1 && log "Promtail config verification: OK" || warn "Promtail config verification reported issues."
fi
journalctl -u promtail -n 30 --no-pager || true
log "Done. Try: {job=\"systemd\",host=\"${APP_NAME}\"} in Grafana → Explore."

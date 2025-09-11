#!/usr/bin/env bash
set -euo pipefail

DEFAULT_LOKI_IP="${DEFAULT_LOKI_IP:-10.0.2.35}"
ALLOY_DIR="/etc/alloy"
ALLOY_CFG="${ALLOY_DIR}/config.alloy"

log(){ >&2 printf "\033[1;32m==>\033[0m %s\n" "$*"; }
warn(){ >&2 printf "\033[1;33m!!\033[0m %s\n" "$*"; }
die(){ >&2 printf "\033[1;31mXX\033[0m %s\n" "$*"; exit 1; }
ask(){ local p="$1" v=""; if [[ -t 0 ]]; then read -rp "$p" v; else read -rp "$p" v </dev/tty || true; fi; printf "%s" "$v"; }

# OS
[[ -r /etc/os-release ]] || die "No /etc/os-release"
. /etc/os-release; log "Detected ${ID^} ${VERSION_ID:-unknown}"

# Inputs
APP_NAME="${APP_NAME:-}"; [[ -z "$APP_NAME" ]] && APP_NAME="$(ask 'Application name for this LXC (e.g. jellyfin): ')"
[[ -z "$APP_NAME" ]] && die "Application name is required."
LOKI_IN="$(ask "Loki IP or URL [${DEFAULT_LOKI_IP}]: ")"; LOKI_IN="${LOKI_IN:-$DEFAULT_LOKI_IP}"
if [[ "$LOKI_IN" =~ ^https?:// ]]; then LOKI_URL="${LOKI_IN%/}/loki/api/v1/push"; else LOKI_URL="http://${LOKI_IN}:3100/loki/api/v1/push"; fi
log "Logs → ${LOKI_URL}"

# Resolve a unit (best effort)
norm(){ [[ "$1" == *.service ]] && printf %s "$1" || printf %s "$1.service"; }
pick() {
  local hint="$1"; local -a c=(); local l
  while read -r l; do c+=("${l%% *}"); done < <(systemctl list-units --type=service --all --no-legend | grep -i "$hint" || true)
  while read -r l; do c+=("${l%% *}"); done < <(systemctl list-unit-files --type=service --no-legend | grep -i "$hint" || true)
  c+=("$(norm "$hint")" "$(norm "${hint,,}")")
  mapfile -t c < <(printf "%s\n" "${c[@]}" | awk 'NF' | sort -fu)
  (( ${#c[@]} )) || return 1
  if (( ${#c[@]}==1 )); then printf "%s" "${c[0]}"; else
    log "Multiple services matched '${hint}':"; local i=1; for s in "${c[@]}"; do >&2 printf "  [%d] %s\n" "$i" "$s"; ((i++)); done
    local ch; ch="$(ask 'Select [1]: ')"; ch="${ch:-1}"
    if [[ "$ch" =~ ^[0-9]+$ ]] && (( ch>=1 && ch<=${#c[@]} )); then printf "%s" "${c[ch-1]}"; else printf "%s" "${c[0]}"; fi
  fi
}
SERVICE_NAME="${SERVICE_NAME:-}"
if [[ -z "$SERVICE_NAME" ]]; then if SERVICE_NAME="$(pick "$APP_NAME")"; then SERVICE_NAME="$(norm "$SERVICE_NAME")"; log "Using service: $SERVICE_NAME"; else warn "No unit matched '${APP_NAME}'. Skipping override."; SERVICE_NAME=""; fi; fi

# Install Alloy
apt-get update
apt-get install -y curl gpg ca-certificates
mkdir -p /etc/apt/keyrings
[[ -s /etc/apt/keyrings/grafana.gpg ]] || curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
[[ -s /etc/apt/sources.list.d/grafana.list ]] || echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update
apt-get install -y alloy

# Journald override for the app
if [[ -n "$SERVICE_NAME" ]]; then
  mkdir -p "/etc/systemd/system/${SERVICE_NAME}.d"
  cat > "/etc/systemd/system/${SERVICE_NAME}.d/override.conf" <<EOF
[Service]
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${APP_NAME}
EOF
  systemctl daemon-reload
  systemctl restart "$SERVICE_NAME" || warn "Restart failed; verify the unit."
fi

# Journald persistence & Alloy perms
mkdir -p /var/log/journal
systemctl restart systemd-journald || true
usermod -aG systemd-journal alloy || true
usermod -aG adm alloy || true

# Alloy config (logs → Loki, metrics exposed on :9100)
mkdir -p "${ALLOY_DIR}"
cat > "${ALLOY_CFG}" <<RIVER
loki.source.journal "journald" {
  path   = "/var/log/journal"
  labels = { job = "systemd", host = "${APP_NAME}" }
  forward_to = [loki.process.journal.receiver]
}

loki.process "journal" {
  stage { template { source = "unit" template = "{{ .__journal__systemd_unit }}" } }
  stage { template { source = "app"  template = "{{ .__journal__syslog_identifier }}" } }
  stage { labels { unit = "unit", app = "app" } }
  forward_to = [loki.write.out.receiver]
}

loki.write "out" {
  endpoint { url = "${LOKI_URL}" }
}

prometheus.exporter.node "local" {}   # exposes :9100/metrics
prometheus.scrape "node" {
  targets    = [prometheus.exporter.node.local.target]
  forward_to = []                     # pull-only; Prometheus will scrape us
}
RIVER

systemctl enable --now alloy
systemctl --no-pager --full status alloy || true

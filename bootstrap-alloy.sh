#!/usr/bin/env bash
set -euo pipefail

DEFAULT_LOKI_IP="${DEFAULT_LOKI_IP:-10.0.2.35}"
DEFAULT_PROM_URL="${DEFAULT_PROM_URL:-http://10.0.2.35:9090}"

ALLOY_DIR="/etc/alloy"
ALLOY_CFG="${ALLOY_DIR}/config.alloy"

log(){ >&2 printf "\033[1;32m==>\033[0m %s\n" "$*"; }
warn(){ >&2 printf "\033[1;33m!!\033[0m %s\n" "$*"; }
die(){ >&2 printf "\033[1;31mXX\033[0m %s\n" "$*"; exit 1; }
ask(){ local p="${1-}"; local v=""; printf "%s" "$p" >&2; read -r v </dev/tty || v=""; printf "%s" "$v"; }

# Safe helpers (never touch bare $1 with set -u)
norm(){
  local x="${1-}"
  [[ -n "${x}" ]] || return 1
  if [[ "$x" == *.service ]]; then printf %s "$x"; else printf %s "$x.service"; fi
}
pick(){
  local hint="${1-}"
  [[ -n "${hint}" ]] || return 1
  local -a c=(); local l
  while read -r l; do c+=("${l%% *}"); done < <(systemctl list-units --type=service --all --no-legend | grep -iF "$hint" || true)
  while read -r l; do c+=("${l%% *}"); done < <(systemctl list-unit-files --type=service --no-legend | grep -iF "$hint" || true)
  # try obvious variants, but guard norm
  local n
  n="$(norm "$hint" 2>/dev/null || true)";       [[ -n "$n" ]] && c+=("$n")
  n="$(norm "${hint,,}" 2>/dev/null || true)";   [[ -n "$n" ]] && c+=("$n")
  # uniq
  mapfile -t c < <(printf "%s\n" "${c[@]}" | awk 'NF' | sort -fu)
  (( ${#c[@]} )) || return 1
  if (( ${#c[@]} == 1 )); then
    printf "%s" "${c[0]}"
  else
    >&2 printf "\033[1;32m==>\033[0m Multiple services matched '%s':\n" "$hint"
    local i=1; for s in "${c[@]}"; do >&2 printf "  [%d] %s\n" "$i" "$s"; ((i++)); done
    >&2 printf "Select [1]: "
    local ch; read -r ch </dev/tty || ch=""
    ch="${ch:-1}"
    if [[ "$ch" =~ ^[0-9]+$ ]] && (( ch>=1 && ch<=${#c[@]} )); then printf "%s" "${c[ch-1]}"; else printf "%s" "${c[0]}"; fi
  fi
}

# OS
[[ -r /etc/os-release ]] || die "No /etc/os-release"
. /etc/os-release; log "Detected ${ID^} ${VERSION_ID:-unknown}"

# Inputs
APP_NAME="${APP_NAME:-}"
[[ -z "$APP_NAME" ]] && APP_NAME="$(ask 'Application name for this LXC (e.g. jellyfin): ')"
[[ -z "$APP_NAME" ]] && die "Application name is required."

LOKI_IN="$(ask "Loki IP or URL [${DEFAULT_LOKI_IP}]: ")"; LOKI_IN="${LOKI_IN:-$DEFAULT_LOKI_IP}"
# Build LOKI_URL robustly
if [[ "$LOKI_IN" =~ ^https?:// ]]; then
  LOKI_URL="${LOKI_IN%/}"; [[ "$LOKI_URL" =~ /loki/api/v1/push$ ]] || LOKI_URL="${LOKI_URL}/loki/api/v1/push"
else
  # allow ip:port
  if [[ "$LOKI_IN" =~ :[0-9]+$ ]]; then
    LOKI_URL="http://${LOKI_IN%/}/loki/api/v1/push"
  else
    LOKI_URL="http://${LOKI_IN}:3100/loki/api/v1/push"
  fi
fi
log "Logs → ${LOKI_URL}"

PROM_IN="$(ask "Prometheus base URL for remote_write [${DEFAULT_PROM_URL}]: ")"; PROM_IN="${PROM_IN:-$DEFAULT_PROM_URL}"
PROM_URL="${PROM_IN%/}"; PROM_WRITE="${PROM_URL}/api/v1/write"
log "Metrics remote_write → ${PROM_WRITE}"

# Resolve a unit (best effort)
SERVICE_NAME="${SERVICE_NAME:-}"
if [[ -z "$SERVICE_NAME" ]]; then
  if SERVICE_NAME="$(pick "$APP_NAME" 2>/dev/null)"; then
    SERVICE_NAME="$(norm "$SERVICE_NAME" 2>/dev/null || true)"
    log "Using service: ${SERVICE_NAME}"
  else
    warn "No unit matched '${APP_NAME}'. Skipping journald override."
    SERVICE_NAME=""
  fi
fi

# Install Alloy
apt-get update
apt-get install -y curl gpg ca-certificates
mkdir -p /etc/apt/keyrings
[[ -s /etc/apt/keyrings/grafana.gpg ]] || curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
[[ -s /etc/apt/sources.list.d/grafana.list ]] || echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update
apt-get install -y alloy

# Journald override for the app (optional)
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

# Alloy config (logs → Loki, metrics → Prom remote_write)
mkdir -p "${ALLOY_DIR}"
cat > "${ALLOY_CFG}" <<"RIVER"
// ---------- LOGS: journald -> Loki ----------
// Shared relabel rules (for app/unit labels)
loki.relabel "journal_rules" {
  forward_to = []

  rule {
    action        = "replace"
    source_labels = ["__journal__systemd_unit"]
    target_label  = "unit"
    regex         = "(.+)"
    replacement   = "$1"
  }

  rule {
    action        = "replace"
    source_labels = ["__journal__syslog_identifier"]
    target_label  = "app"
    regex         = "(.+)"
    replacement   = "$1"
  }

  rule {
    action        = "replace"
    source_labels = ["__journal__systemd_unit"]
    target_label  = "app"
    regex         = "^(.+?)(?:\\.(?:service|slice|scope))?$"
    replacement   = "$1"
  }

  rule {
    action        = "replace"
    source_labels = ["__journal__unit"]
    target_label  = "app"
    regex         = "^(.+?)(?:\\.(?:service|slice|scope))?$"
    replacement   = "$1"
  }
}

// Parse and NORMALISE log levels into a real 'level' LABEL
loki.process "levels" {
  forward_to = [loki.write.out.receiver]

  // style 1: key=value (e.g., level=warn)
  stage.regex {
    expression = "(?i)\\blevel\\s*=\\s*(?P<level>[a-z]+)\\b"
  }

  // style 2: bracketed (e.g., [Info])
  stage.regex {
    expression = "(?i)\\[(?P<level>trace|debug|info|warn|warning|error|fatal|critical)\\]"
  }

  // normalise: WARNING -> warn, and lowercase everything else
  stage.template {
    source   = "level"
    template = "{{ if eq (ToLower .Value) \"warning\" }}warn{{ else }}{{ ToLower .Value }}{{ end }}"
  }

  // promote to a LABEL only if we extracted something
  stage.labels {
    values = { level = "level" }
  }
}

loki.source.journal "read" {
  labels        = { job = "systemd", host = env("HOSTNAME") }
  relabel_rules = loki.relabel.journal_rules.rules
  forward_to    = [loki.process.levels.receiver]
}

loki.write "out" {
  endpoint { url = "LOKI_URL_PLACEHOLDER" }
}

// ---------- METRICS: scrape locally, push to Prometheus ----------
prometheus.exporter.unix "node" {}

prometheus.scrape "node" {
  targets         = prometheus.exporter.unix.node.targets
  scrape_interval = "15s"
  forward_to      = [prometheus.remote_write.to_prom.receiver]
}

prometheus.remote_write "to_prom" {
  endpoint { url = "PROM_WRITE_PLACEHOLDER" }
}
RIVER

# Substitute the actual URLs
sed -i "s|LOKI_URL_PLACEHOLDER|${LOKI_URL}|g" "${ALLOY_CFG}"
sed -i "s|PROM_WRITE_PLACEHOLDER|${PROM_WRITE}|g" "${ALLOY_CFG}"

systemctl enable --now alloy
systemctl --no-pager --full status alloy || true

log "Done. Check: journalctl -u alloy -n 100 --no-pager"

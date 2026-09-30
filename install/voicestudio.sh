#!/usr/bin/env bash
# VoiceStudio Proxmox VM Installer (Community-Scripts-Stil, Einzeiler-fähig)
#
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/VoiceStudio/main/install/voicestudio.sh)"
#
#Nur eigener Installer-Code (MIT). Die App selbst stammt von Upstream
#https://github.com/debpalash/VoiceStudio (AGPL-3.0) und läuft als offizielles
#Docker-Image ghcr.io/debpalash/voicestudio — kein Upstream-Code in diesem Repo.
#
#Was das Skript tut (idempotent, set -euo pipefail):
# 1. nimmt die nächste freie VMID (pvesh get /cluster/nextid), außer --vmid gesetzt
# 2. lädt das Debian-13-Cloud-Image (einmalig, SHA512-geprüft wenn möglich)
# 3. erstellt eine VM (Hostname voicestudio, onboot: 1, qemu-guest-agent, cloud-init)
# 4. installiert im Gast Docker + Compose-Plugin (Debian-Pakete, kein Fremd-Script)
# 5. legt /opt/voicestudio/{docker-compose.yml,.env} + systemd-Unit an, enable --now
# 6. verifiziert: systemctl is-active + HTTP /health, gibt finale URL + VM-IP aus
# Re-Run mit --vmid = Update (Images pull, Secrets bleiben, restart).
set -euo pipefail

APP="voicestudio"
PORT="3900"
IMAGE="ghcr.io/debpalash/voicestudio"
DEBIAN_IMG_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
DEBIAN_SUM_URL="https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"
IMG_CACHE="/var/tmp/voicestudio-debian13.qcow2"

DEFAULT_TAG="stable"
DEFAULT_CORES="4"
DEFAULT_RAM="8192"
DEFAULT_DISK="30"
DEFAULT_BRIDGE="vmbr0"

C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_BLUE='\033[0;34m'; C_RESET='\033[0m'

# Env-Overrides (GitHub-first, CI-freundlich)
VMID_ARG="${VM_ID:-}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-${MEMORY:-$DEFAULT_RAM}}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"
STORAGE_ARG="${STORAGE:-}"
BRIDGE_ARG="${BRIDGE:-$DEFAULT_BRIDGE}"
TAG_ARG="${TAG:-$DEFAULT_TAG}"
PASSWORD_ARG="${PASSWORD:-}"
SSH_KEY_ARG="${SSH_KEY:-}"
API_KEY_ARG="${API_KEY:-}"
GPU_PROFILE_ARG="${GPU_PROFILE:-cpu}"
LAN_ARG="${LAN:-1}"
DEBUG_ARG="${DEBUG:-0}"

LOG_FILE="/tmp/voicestudio-install-$(date +%Y%m%d-%H%M%S).log"
SCRIPT_ARGS="$*"
DEBUG="$DEBUG_ARG"

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

usage() {
  cat <<EOF
${APP} Proxmox VM Installer

Usage:
  bash voicestudio.sh [OPTIONEN]
  VM_ID=101 bash voicestudio.sh
  bash -c "\$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/VoiceStudio/main/install/voicestudio.sh)"

Optionen:
  --vmid ID            VM-ID (Default: nächste freie ID via 'pvesh get /cluster/nextid')
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM}, Minimum 8192)
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK}, Minimum 20)
  --storage NAME       VM-Disk-Storage, muss dateibasiert sein (Default: auto, bevorzugt local)
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --tag TAG            Image-Tag (Default: ${DEFAULT_TAG}; z. B. latest oder 0.5.6)
  --password PW        root-Passwort der VM (Default: zufällig, wird einmalig angezeigt)
  --ssh-key PATH       zusätzlicher SSH Public Key für die VM (optional)
  --api-key KEY        VoiceStudio API-Key (Default: zufällig generiert, bleibt bei Re-Run erhalten)
  --gpu-profile PROF   cpu|nvidia|rocm (Default: cpu; nvidia/rocm prüft nur + warnt, PCI-Passthrough bleibt manuell)
  --guest-ip IP        Gast-IPv4 direkt vorgeben (überspringt Agent-/ARP-/Sweep-Suche, z. B. aus FritzBox abgelesen)
  --lan                Port 3900 im LAN freigeben (Default: an, 0.0.0.0 – nur mit API-Key nutzen)
  --loopback-only      Port 3900 nur im Gast binden (127.0.0.1, Zugriff per SSH-Tunnel)
  --debug, -x          set -x + maximale Fehlermeldungskette
  --help, -h           diese Hilfe

Update:   bash voicestudio.sh --vmid <ID>   (idempotent: pull + restart, Secrets bleiben)
Deinstall: qm stop <ID> && qm destroy <ID>
EOF
}

# ---------------------------------------------------------------------------
# Debugging: komplette Fehlermeldungskette
# ---------------------------------------------------------------------------
on_error() {
  local exit_code="$1" lineno="$2" cmd="$3"
  set +x
  if ((${#cmd} > 2000)); then
    cmd="${cmd:0:2000}… [gekürzt, vollständiger Befehl in $LOG_FILE]"
  fi
  echo ""
  msg_error "════════════ INSTALLATION FEHLGESCHLAGEN ════════════"
  msg_error "Befehl    : $cmd"
  msg_error "Zeile     : $lineno"
  msg_error "Exit-Code : $exit_code"
  msg_error "Args      : $SCRIPT_ARGS"
  msg_error "Logdatei  : $LOG_FILE (komplette stdout/stderr-Kette)"
  echo ""
  msg_error "--- Stacktrace (neuester Aufruf zuerst) ---"
  local i=0
  while caller "$i"; do ((i++)) || true; done
  echo ""
  if command -v qm >/dev/null 2>&1 && [[ -n "${VMID:-}" ]]; then
    msg_error "--- qm config ${VMID} ---"
    qm config "${VMID}" 2>&1 || true
    echo ""
    msg_error "--- qm status ${VMID} ---"
    qm status "${VMID}" 2>&1 || true
    echo ""
    if [[ -n "${GUEST_IP:-}" && -n "${SSH_KEY:-}" ]]; then
      msg_error "--- systemctl status im Gast (voicestudio) ---"
      ssh_guest "systemctl status ${APP} --no-pager --full" 2>&1 || true
      echo ""
      msg_error "--- journalctl im Gast (voicestudio, letzte 100 Zeilen) ---"
      ssh_guest "journalctl -u ${APP} --no-pager -n 100" 2>&1 || true
      echo ""
      msg_error "--- docker ps im Gast ---"
      ssh_guest "docker ps -a" 2>&1 || true
      echo ""
      msg_error "--- docker compose logs (letzte 100 Zeilen) ---"
      ssh_guest "docker compose -f /opt/${APP}/docker-compose.yml logs --tail=100 --no-color" 2>&1 || true
    fi
  fi
  echo ""
  msg_error "Re-run mit vollem Trace:"
  # shellcheck disable=SC2086
  msg_error "  bash -x voicestudio.sh $SCRIPT_ARGS"
  msg_error "Bitte bei Fehlermeldungen IMMER die komplette Logdatei ($LOG_FILE) mitschicken."
  exit "$exit_code"
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
VMID="$VMID_ARG"
CORES="$CORES_ARG"
RAM="$RAM_ARG"
DISK="$DISK_ARG"
STORAGE="$STORAGE_ARG"
BRIDGE="$BRIDGE_ARG"
TAG="$TAG_ARG"
ROOT_PASSWORD="$PASSWORD_ARG"
EXTRA_SSH_KEY="$SSH_KEY_ARG"
API_KEY="$API_KEY_ARG"
GPU_PROFILE="$GPU_PROFILE_ARG"
LAN="$LAN_ARG"
GUEST_IP_OVERRIDE="${GUEST_IP:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid)        VMID="${2:?--vmid braucht einen Wert}"; shift 2 ;;
    --cores)       CORES="${2:?}"; shift 2 ;;
    --memory)      RAM="${2:?}"; shift 2 ;;
    --disk)        DISK="${2:?}"; shift 2 ;;
    --storage)     STORAGE="${2:?}"; shift 2 ;;
    --bridge)      BRIDGE="${2:?}"; shift 2 ;;
    --tag)         TAG="${2:?}"; shift 2 ;;
    --password)    ROOT_PASSWORD="${2:?}"; shift 2 ;;
    --ssh-key)     EXTRA_SSH_KEY="${2:?}"; shift 2 ;;
    --api-key)     API_KEY="${2:?}"; shift 2 ;;
    --gpu-profile) GPU_PROFILE="${2:?}"; shift 2 ;;
    --guest-ip)    GUEST_IP_OVERRIDE="${2:?--guest-ip braucht eine IPv4}"; shift 2 ;;
    --lan)         LAN="1"; shift ;;
    --loopback-only) LAN="0"; shift ;;
    --debug|-x)    DEBUG="1"; set -x; shift ;;
    --help|-h)     usage; exit 0 ;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1 ;;
  esac
done

# Trap NACH dem Parsen setzen, damit SCRIPT_ARGS die echten Args enthält
# shellcheck disable=SC2064
trap "on_error \$? \$LINENO \"\$BASH_COMMAND\"" ERR

# ---------------------------------------------------------------------------
# Pre-Checks (Proxmox-Host, root, amd64)
# ---------------------------------------------------------------------------
msg_info "Prüfe Voraussetzungen (Proxmox-Host, root, Tools) ..."
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  msg_error "Bitte als root auf dem Proxmox-Host ausführen (sudo -i)."
  exit 1
fi
for bin in qm pvesh pvesm wget curl ssh python3 openssl; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    msg_error "Benötigtes Tool fehlt: $bin – läuft das Skript wirklich auf einem Proxmox-VE-Host?"
    exit 1
  fi
done
if [[ "$(uname -m)" != "x86_64" ]]; then
  msg_error "Nur amd64 wird unterstützt (Upstream-Image ist linux/amd64-only). Gefunden: $(uname -m)"
  exit 1
fi
if [[ "$RAM" -lt 8192 ]]; then
  msg_warn "RAM=${RAM} MB < 8192 MB – VoiceStudio (Modelle ~2,4–4 GB) braucht min. 8 GB, sonst OOM."
fi
if [[ "$DISK" -lt 20 ]]; then
  msg_warn "DISK=${DISK} GB < 20 GB – Image + Modelle + Docker brauchen min. ~20 GB."
fi
case "$GPU_PROFILE" in
  cpu|nvidia|rocm) ;;
  *) msg_error "Ungültiges --gpu-profile: $GPU_PROFILE (nur cpu|nvidia|rocm)"; exit 1 ;;
esac
msg_ok "Host-Checks bestanden."

# ---------------------------------------------------------------------------
# VM-ID: immer die nächste freie ID nehmen (außer explizit gesetzt)
# ---------------------------------------------------------------------------
if [[ -z "$VMID" ]]; then
  msg_info "Ermittle nächste freie VM-ID ..."
  VMID="$(pvesh get /cluster/nextid)"
  msg_ok "Nächste freie VM-ID: $VMID"
else
  msg_info "VM-ID vorgegeben: $VMID"
fi

# ---------------------------------------------------------------------------
# Storage-Erkennung (dateibasiert, content images; bevorzugt local)
# ---------------------------------------------------------------------------
if [[ -z "$STORAGE" ]]; then
  msg_info "Erkenne Storage (dateibasiert, content images) ..."
  STORAGE="$(pvesm status --content images 2>/dev/null | awk 'NR>1 && /active/ {print $1}' | grep -x "local" || true)"
  if [[ -z "$STORAGE" ]]; then
    STORAGE="$(pvesm status --content images 2>/dev/null | awk 'NR>1 && /active/ {print $1}' | head -n1 || true)"
  fi
  if [[ -z "$STORAGE" ]]; then
    msg_error "Kein aktiver Storage mit content=images gefunden."
    exit 1
  fi
  msg_ok "Storage: $STORAGE"
fi
STORAGE_TYPE="$(pvesm status 2>/dev/null | awk -v s="$STORAGE" 'NR>1 && $1==s {print $2}')"
case "$STORAGE_TYPE" in
  dir|nfs|cifs|glusterfs|cephfs) msg_ok "Storage-Typ ok ($STORAGE_TYPE)." ;;
  *)
    msg_error "Storage $STORAGE ist Typ $STORAGE_TYPE – Cloud-Image-Import braucht dateibasierten Storage (dir/nfs/cifs)."
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Secrets (nur zur Laufzeit generiert, niemals committet)
# ---------------------------------------------------------------------------
if [[ -z "$ROOT_PASSWORD" ]]; then
  ROOT_PASSWORD="$(openssl rand -hex 8)"
  ROOT_PW_GENERATED="1"
else
  ROOT_PW_GENERATED="0"
fi
if [[ -z "$API_KEY" ]]; then
  API_KEY="$(openssl rand -hex 32)"
  msg_info "API-Key generiert (bleibt bei Re-Run mit --vmid erhalten)."
fi

# SSH-Key für den Gast (idempotent wiederverwendet)
SSH_KEY="/root/.ssh/voicestudio_proxmox"
if [[ ! -f "$SSH_KEY" ]]; then
  msg_info "Erzeuge SSH-Key für Gast-Zugang ..."
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "voicestudio-proxmox-installer" >/dev/null
fi

# ---------------------------------------------------------------------------
# Debian-13-Cloud-Image (einmalig laden, Größe prüfen, SHA512 wenn möglich)
# ---------------------------------------------------------------------------
if [[ -f "$IMG_CACHE" && "$(stat -c%s "$IMG_CACHE" 2>/dev/null || echo 0)" -gt 100000000 ]]; then
  msg_ok "Cloud-Image bereits vorhanden ($IMG_CACHE)."
else
  msg_info "Lade Debian-13-Cloud-Image (~300 MB, einmalig) ..."
  wget -q --show-progress -O "$IMG_CACHE" "$DEBIAN_IMG_URL"
  msg_info "Prüfe SHA512 (warn-only) ..."
  if wget -q -O /var/tmp/voicestudio-SHA512SUMS "$DEBIAN_SUM_URL"; then
    (cd /var/tmp && sha512sum -c --status <(grep "debian-13-genericcloud-amd64.qcow2" voicestudio-SHA512SUMS) 2>/dev/null && msg_ok "SHA512 ok.") || msg_warn "SHA512-Prüfung übersprungen/fehlgeschlagen – fahre fort (Größen-Check bestanden)."
  else
    msg_warn "Checksummen-Datei nicht ladbar – fahre fort (Größen-Check bestanden)."
  fi
fi

# ---------------------------------------------------------------------------
# VM erstellen oder übernehmen (idempotent)
# ---------------------------------------------------------------------------
EXISTING="0"
if qm status "$VMID" >/dev/null 2>&1; then
  EXISTING="1"
  msg_info "VM $VMID existiert bereits – übernehme (Update-Pfad, keine Neu-Erstellung)."
else
  msg_info "Erstelle VM $VMID (voicestudio, ${CORES} vCPU / ${RAM} MB / ${DISK} GB, onboot=1) ..."
  SSHKEY_OPT=("$SSH_KEY.pub")
  if [[ -n "$EXTRA_SSH_KEY" ]]; then
    cat "$EXTRA_SSH_KEY" >> "$SSH_KEY.pub.allow" 2>/dev/null || true
  fi
  qm create "$VMID" \
    --name "$APP" --ostype l26 \
    --memory "$RAM" --cores "$CORES" --cpu host \
    --scsihw virtio-scsi-single \
    --net0 "virtio,bridge=$BRIDGE" \
    --scsi0 "$STORAGE:0,import-from=$IMG_CACHE,cache=writeback,discard=on" \
    --ide2 "$STORAGE:cloudinit" \
    --boot order=scsi0 --serial0 socket --vga serial0 \
    --agent enabled=1 \
    --onboot 1 \
    --ciuser root --cipassword "$ROOT_PASSWORD" \
    --sshkeys "$SSH_KEY.pub" \
    --ipconfig0 ip=dhcp
  qm resize "$VMID" scsi0 "${DISK}G"
  msg_ok "VM $VMID erstellt."
fi

# SCSI-Controller normalisieren: lsi sieht die Cloud-Initramfs-Platte nicht
# (kein "Attached scsi disk" -> Root-Mount-Stall). virtio-scsi-single heilt
# Neu- und Bestands-VMs gleichermaßen; braucht einmalig einen Neustart.
CURRENT_SCSIHW="$(qm config "$VMID" 2>/dev/null | awk '/^scsihw:/ {print $2}')"
if [[ "${CURRENT_SCSIHW:-lsi}" != "virtio-scsi-single" ]]; then
  msg_warn "SCSI-Controller ist ${CURRENT_SCSIHW:-lsi (Default)} – stelle auf virtio-scsi-single um ..."
  if qm status "$VMID" 2>/dev/null | grep -q "status: running"; then
    msg_info "Stoppe VM $VMID für Controller-Wechsel ..."
    qm shutdown "$VMID" --timeout 60 >/dev/null 2>&1 || qm stop "$VMID" >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
      qm status "$VMID" 2>/dev/null | grep -q "status: stopped" && break
      sleep 5
    done
  fi
  qm set "$VMID" --scsihw virtio-scsi-single
  msg_ok "SCSI-Controller: virtio-scsi-single."
fi

if ! qm status "$VMID" 2>/dev/null | grep -q "status: running"; then
  msg_info "Starte VM $VMID ..."
  qm start "$VMID"
fi

# ---------------------------------------------------------------------------
# SSH-Helfer (Gast-Kommandos; Exit-Codes + stdout/stderr bleiben erhalten)
# ---------------------------------------------------------------------------
GUEST_IP=""
AGENT_UP="0"
msg_info "Prüfe qemu-guest-agent (optional, 60 s) ..."
for _ in $(seq 1 12); do
  if qm guest cmd "$VMID" ping >/dev/null 2>&1; then AGENT_UP="1"; break; fi
  sleep 5
done
if [[ "$AGENT_UP" == "1" ]]; then
  msg_ok "Guest-Agent antwortet."
else
  msg_warn "Guest-Agent antwortet nicht (Debian-Cloud-Images bringen ihn teils nicht mit) – fahre ohne Agent fort, IP per ARP."
fi

resolve_ip_via_agent() {
  qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | python3 -c '
import json,sys
try:
  data = json.load(sys.stdin)
except Exception:
  sys.exit(0)
for iface in data if isinstance(data, list) else []:
  if iface.get("name") == "lo":
    continue
  for addr in iface.get("ip-addresses", []):
    ip = addr.get("ip-address", "")
    if addr.get("ip-address-type") == "ipv4" and not ip.startswith("127."):
      print(ip)
      sys.exit(0)
' || true
}

resolve_ip_via_arp() {
  local mac ip
  mac="$(qm config "$VMID" 2>/dev/null | grep -E '^net0:' | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -1 | tr '[:upper:]' '[:lower:]')"
  [[ -z "$mac" ]] && return 0
  ip="$(ip -4 neigh show dev "$BRIDGE" 2>/dev/null | grep -i "$mac" | grep -v FAILED | awk '{print $1}' | head -1)"
  # "Noch keine IP" ist kein Fehler (Polling) -> immer 0 zurück, sonst killt set -e die Schleife.
  if [[ -n "$ip" ]]; then echo "$ip"; fi
  return 0
}

# Aktiver Sweep: stiller Gast -> keine ARP-Einträge -> passives Warten findet nie etwas.
# Ping-Sweep über das /24 der Bridge füllt die ARP-Tabelle neu (einmalig + alle ~2 Min).
sweep_subnet_once() {
  local cidr net i
  cidr="$(ip -4 -o addr show dev "$BRIDGE" 2>/dev/null | awk '{print $4}' | head -1)"
  case "$cidr" in
    */24) ;;
    *) msg_warn "Sweep übersprungen (Bridge $BRIDGE hat kein /24: ${cidr:-keine IPv4})."; return 0 ;;
  esac
  net="${cidr%.*}"
  msg_info "Sweep $net.2-254 zum Füllen der ARP-Tabelle ..."
  for i in $(seq 2 254); do ping -c1 -W1 "$net.$i" >/dev/null 2>&1 & done
  wait || true
}

if [[ -n "${GUEST_IP_OVERRIDE:-}" ]]; then
  if ! [[ "$GUEST_IP_OVERRIDE" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    msg_error "Ungültige --guest-ip: $GUEST_IP_OVERRIDE (IPv4 erwartet, z. B. 192.168.178.142)"
    exit 1
  fi
  GUEST_IP="$GUEST_IP_OVERRIDE"
  msg_ok "Gast-IP vorgegeben (--guest-ip): $GUEST_IP"
else
  msg_info "Ermittle Gast-IP (Agent, sonst ARP/Sweep über $BRIDGE, bis ~6 Min) ..."
  for i in $(seq 1 60); do
    if [[ "$AGENT_UP" == "1" ]]; then
      GUEST_IP="$(resolve_ip_via_agent)"
    fi
    if [[ -z "$GUEST_IP" ]]; then
      GUEST_IP="$(resolve_ip_via_arp)"
    fi
    if [[ -z "$GUEST_IP" && $((i % 30)) == 1 ]]; then
      sweep_subnet_once
      GUEST_IP="$(resolve_ip_via_arp)"
    fi
    if [[ -n "$GUEST_IP" ]]; then break; fi
    sleep 5
  done
fi
if [[ -z "$GUEST_IP" ]]; then
  msg_error "Keine Gast-IP gefunden (weder Agent noch ARP/Sweep auf $BRIDGE). DHCP prüfen oder --guest-ip <IP> direkt übergeben."
  exit 1
fi
msg_ok "Gast-IP: $GUEST_IP"

ssh_guest() {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o ServerAliveInterval=30 -i "$SSH_KEY" "root@$GUEST_IP" "$@"
}

msg_info "Warte auf SSH im Gast ..."
for _ in $(seq 1 24); do
  if ssh_guest "true" >/dev/null 2>&1; then break; fi
  sleep 5
done
ssh_guest "true" >/dev/null 2>&1 || { msg_error "SSH als root@$GUEST_IP schlägt fehl (Key: $SSH_KEY.pub)."; exit 1; }
msg_ok "SSH steht."

# Update- oder Neuinstallation?
UPDATE="0"
if ssh_guest "test -f /opt/${APP}/docker-compose.yml" >/dev/null 2>&1; then
  UPDATE="1"
  msg_info "Bestehende Installation gefunden – Update-Pfad (Secrets bleiben erhalten)."
fi

# ---------------------------------------------------------------------------
# Gast: Docker + Compose v2 (Docker aus Debian, Compose als offizielles Binary:
# docker-compose-plugin existiert in Trixie-Main nicht -> apt bricht sonst alles ab)
# ---------------------------------------------------------------------------
msg_info "Installiere Docker + Compose v2 im Gast (apt + offizielles Binary, idempotent) ..."
ssh_guest "for i in \$(seq 1 30); do fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break; sleep 10; done"
ssh_guest "export DEBIAN_FRONTEND=noninteractive && apt-get update -qq && apt-get install -y -qq ca-certificates curl qemu-guest-agent docker.io && systemctl enable --now qemu-guest-agent docker"
ssh_guest "mkdir -p /usr/local/lib/docker/cli-plugins /usr/libexec/docker/cli-plugins && curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose && ln -sf /usr/local/lib/docker/cli-plugins/docker-compose /usr/libexec/docker/cli-plugins/docker-compose"
ssh_guest "docker --version && docker compose version"
msg_ok "Docker + Compose bereit."

# ---------------------------------------------------------------------------
# Gast: /opt/voicestudio (compose + .env + systemd-Unit)
# ---------------------------------------------------------------------------
PUBLISH="127.0.0.1:3900:3900"
if [[ "$LAN" == "1" ]]; then PUBLISH="0.0.0.0:3900:3900"; fi

msg_info "Schreibe /opt/${APP}/docker-compose.yml ..."
COMPOSE_B64="$(cat <<COMPOSE_EOF | base64 -w0
services:
  omnivoice:
    image: ${IMAGE}:${TAG}
    container_name: ${APP}
    ports:
      - "\${PUBLISH}"
    environment:
      - OMNIVOICE_API_KEY=\${OMNIVOICE_API_KEY}
      - OMNIVOICE_SERVER_MODE=1
      - OMNIVOICE_BIND_HOST=0.0.0.0
      - OMNIVOICE_DATA_DIR=/app/omnivoice_data
      - HF_HOME=/app/omnivoice_data/huggingface
    volumes:
      - voicestudio-data:/app/omnivoice_data
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:3900/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 180s

volumes:
  voicestudio-data:
COMPOSE_EOF
)"
ssh_guest "mkdir -p /opt/${APP} && echo '${COMPOSE_B64}' | base64 -d > /opt/${APP}/docker-compose.yml"

if [[ "$UPDATE" == "0" ]] || ! ssh_guest "test -f /opt/${APP}/.env" >/dev/null 2>&1; then
  msg_info "Schreibe /opt/${APP}/.env (Secrets bleiben bei Update erhalten) ..."
  ssh_guest "printf 'OMNIVOICE_API_KEY=${API_KEY}\nPUBLISH=${PUBLISH}\n' > /opt/${APP}/.env && chmod 600 /opt/${APP}/.env"
else
  msg_info "Aktualisiere PUBLISH in bestehender .env (API-Key bleibt) ..."
  ssh_guest "sed -i 's|^PUBLISH=.*|PUBLISH=${PUBLISH}|' /opt/${APP}/.env"
  API_KEY="$(ssh_guest "grep '^OMNIVOICE_API_KEY=' /opt/${APP}/.env | cut -d= -f2")"
fi

msg_info "Schreibe systemd-Unit ..."
UNIT_B64="$(cat <<UNIT_EOF | base64 -w0
[Unit]
Description=VoiceStudio (Proxmox VM, Docker Compose)
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/voicestudio
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
ExecReload=/usr/bin/docker compose pull
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
UNIT_EOF
)"
ssh_guest "echo '${UNIT_B64}' | base64 -d > /etc/systemd/system/${APP}.service && systemctl daemon-reload && systemctl enable --now ${APP}"

# ---------------------------------------------------------------------------
# Gast: GPU-Hinweis (MVP: prüfen + warnen, kein automatisches Passthrough)
# ---------------------------------------------------------------------------
if [[ "$GPU_PROFILE" != "cpu" ]]; then
  if ssh_guest "command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L 2>/dev/null | grep -q GPU" 2>/dev/null; then
    msg_ok "NVIDIA-GPU im Gast sichtbar."
  elif ssh_guest "test -e /dev/kfd" >/dev/null 2>&1; then
    msg_ok "AMD-GPU-Device (/dev/kfd) im Gast sichtbar."
  else
    msg_warn "GPU-Profil $GPU_PROFILE gewählt, aber keine GPU im Gast gefunden – laufe auf CPU weiter."
    msg_warn "Für GPU: PCI-Passthrough am Host einrichten (IOMMU), VM stoppen/starten, Skript mit --vmid erneut laufen lassen."
  fi
fi

# ---------------------------------------------------------------------------
# Start + Warten auf /health (erster Start zieht Image + ~2,4 GB Modelle)
# ---------------------------------------------------------------------------
msg_info "Starte VoiceStudio (erster Start lädt Image + Modelle, dauert Minuten) ..."
ssh_guest "systemctl restart ${APP}"
msg_info "Warte auf HTTP 200 an localhost:${PORT}/health (Erststart: Image + Modelle, bis ~10 Min) ..."
HEALTH_OK="0"
for _ in $(seq 1 120); do
  if ssh_guest "curl -fs http://127.0.0.1:${PORT}/health >/dev/null 2>&1" >/dev/null 2>&1; then HEALTH_OK="1"; break; fi
  sleep 5
done

# ---------------------------------------------------------------------------
# Verifikation: Service + Web UI + onboot
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."
if ! ssh_guest "systemctl is-active ${APP}" 2>/dev/null | grep -q "active"; then
  msg_error "Service ${APP} ist nicht active."
  exit 1
fi
msg_ok "Service läuft (systemctl is-active ${APP} = active)."
if [[ "$HEALTH_OK" != "1" ]]; then
  msg_error "Web UI antwortet nicht (kein HTTP 200 auf localhost:${PORT}/health nach ~4 Min)."
  exit 1
fi
msg_ok "Web UI antwortet (HTTP 200 auf localhost:${PORT}/health)."
if ! qm config "$VMID" 2>/dev/null | grep -q "onboot: 1"; then
  msg_error "onboot: 1 fehlt in der VM-Config."
  exit 1
fi
msg_ok "VM startet automatisch (onboot: 1)."

# ---------------------------------------------------------------------------
# Finale Ausgabe
# ---------------------------------------------------------------------------
UI_URL="http://127.0.0.1:${PORT} (im Gast; Tunnel: ssh -L ${PORT}:127.0.0.1:${PORT} root@${GUEST_IP})"
if [[ "$LAN" == "1" ]]; then UI_URL="http://${GUEST_IP}:${PORT}"; fi
echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : VoiceStudio – Open-Source Voice-Studio (Upstream: debpalash/VoiceStudio, AGPL-3.0)"
echo "  VM           : $VMID (Hostname: $APP, onboot=1)"
echo "  Ressourcen   : $CORES vCPU / $RAM MB RAM / $DISK GB Disk"
echo "  Web UI       : $UI_URL"
echo "  API-Key      : beim ersten UI-Aufruf eingeben (in /opt/$APP/.env auf der VM)"
if [[ "$ROOT_PW_GENERATED" == "1" && "$EXISTING" == "0" ]]; then
echo "  Root-Passwort: $ROOT_PASSWORD (nur jetzt angezeigt – sicher ablegen!)"
fi
echo "  Service      : systemctl status $APP  (in der VM via: ssh -i $SSH_KEY root@$GUEST_IP)"
echo "  Stack        : ssh root@$GUEST_IP 'cd /opt/$APP && docker compose ps / docker compose logs -f'"
echo "  Update       : Skript erneut laufen lassen mit --vmid $VMID (idempotent, pull + restart)"
echo "  Deinstall    : qm stop $VMID && qm destroy $VMID"
echo "  Reboot-Test  : qm reboot $VMID && sleep 120 && ssh -i $SSH_KEY root@$GUEST_IP 'systemctl is-active $APP && curl -fs http://127.0.0.1:$PORT/health'"
echo "  Log          : $LOG_FILE"
echo "══════════════════════════════════════════════════════════"

# VoiceStudio auf Proxmox (VM + Docker) — Design Spec

Datum: 2026-09-29
Status: zur Review vorgelegt
Bezug: VoiceStudio Upstream https://github.com/debpalash/VoiceStudio (Open-Source ElevenLabs-Alternative, klonen/designen/dubben/diktieren/transkribieren, 646 Sprachen)

## 1. Verstaendnis / Brief

Gesagt:
- Eigenstaendige App VoiceStudio als Proxmox-Installer im Stil Proxmox VE Community Scripts
- Einzeiler-Installation auf Proxmox-Host, naechste freie ID, passender Hostname
- Lokal ohne Cloud, idempotent, set -euo pipefail, volle Fehlerkette, bash -x Log
- Web UI unter http://[IP]:[PORT], bind 0.0.0.0, systemd Restart=always After=network-online.target, onboot: 1
- Verifikation: systemctl is-active + HTTP-Check + finale URL-Ausgabe
- Deliverables: [app].sh, App-Code inkl. Web UI, systemd-Unit, README, Reboot-Test mit Log

Annahmen (bestaetigt mit Ja am 2026-09-29):
- Installer-only Repo (wie typebot-proxmox/): kein Fork von VoiceStudio, App-Code kommt vom offiziellen Image `ghcr.io/debpalash/voicestudio`
- Default-Tag `:stable` (kein `:latest` rolling), Port 3900, API-Key Auto-Generate wenn leer
- Ansatz A: VM + Docker Compose CPU-Profil, GPU-Flag vorbereitet (cpu|nvidia|rocm, default cpu)
- Ressourcen ueber Template-Defaults: Minimum 4 vCPU / 8 GB / 30 GB statt 1-2 vCPU / 1-2 GB / 4-8 GB

Nicht-Ziele MVP: LXC-Variante, nativen uv-Build ohne Docker, ARM64-Support (Image ist amd64-only), Public-Expose ohne Auth, Remote-Worker-Setup.

## 2. Ansatz-Entscheid

Gewahlt: A — VM (Debian 13) + Docker Compose CPU-Profil.

Verworfene:
- B LXC + Docker (Standard, leicht): Docker-in-LXC fragiler, GPU-Passthrough frickelig, 8-16 GB RAM Workload an der Kante.
- C LXC nativ via uv sync (ohne Docker): Torch/CUDA-Build 10+ Min, bricht Upstream-Paritaet, Update-Pfad manuell.

## 3. Architektur (Sektion 1, freigegeben)

- 1x VM `voicestudio` (Debian 13, amd64): Min 4 vCPU / 8 GB RAM / 30 GB Disk, empfohlen 8 vCPU / 16 GB / 40 GB NVMe, Optimal + GPU (NVIDIA 12-16 GB VRAM + Container Toolkit im Gast oder AMD RDNA3+ mit :rocm + /dev/kfd//dev/dri).
- Im Gast: Docker + Compose-Plugin, `/opt/voicestudio/docker-compose.yml + .env` (Upstream-Profil cpu), Volumes `voicestudio-data` + HF-Cache, Env `OMNIVOICE_SERVER_MODE=1`, `OMNIVOICE_BIND_HOST=0.0.0.0`, `OMNIVOICE_API_KEY` (generiert falls leer).
- systemd-Unit `voicestudio.service` (After=network-online.target docker.service, Restart=always), VM `onboot: 1`.
- Host-Script `install/voicestudio.sh`: naechste freie VMID via `pvesh get /cluster/nextid` (ausser --vmid), Storage-Auto (bevorzugt local-lvm), `qm create`, Cloud-Init/Debian-Template.
- Update: Re-Run idempotent (Images pull, Secrets behalten, restart). Deinstall: `qm stop + qm destroy`.

## 4. Datenfluss (Sektion 2, freigegeben)

1. User setzt optional `VMID, CORES, RAM, DISK, BRIDGE, STORAGE, GPU_PROFILE, API_KEY` oder laeuft Defaults.
2. Host-Script baut VM, installiert Docker im Gast, schreibt Compose + .env + Unit, `systemctl enable --now voicestudio`.
3. Erster Start zieht Image (~GBs) + Models (~2.4-4 GB), `/health` 503 mit Fortschritt bis 200 (Poll bis 240 s).
4. Verifikation: `systemctl is-active voicestudio` = active + `curl localhost:3900/health` = 200 + `qm config` onboot Check.
5. Ausgabe: finale URL `http://<VM-IP>:3900`, VMID/Hostname/Ressourcen, Root-Pass nur jetzt, Service-/Compose-Kommandos, Update-/Deinstall-/Reboot-Zeilen, Logpfad.

## 5. Robustheit / Security / Testing (Sektion 3, freigegeben)

- Fehler: set -euo pipefail, Trap mit Befehl+Zeile+Exit+caller-Stack, dazu qm config/status, journalctl -u voicestudio -n 100, docker ps -a, compose logs --tail=100. Voller stdout+stderr nach /tmp/voicestudio-install-*.log. --debug = bash -x.
- GPU fehlt/falsch: Warnung + CPU-Fallback, kein Abbruch. Arch != amd64: Abbruch mit Hinweis.
- Health: /health je Deploy, Compose depends_on + Restart-Policy, systemd Restart=always.
- Security: Loopback-Mapping Default (127.0.0.1:3900), LAN nur mit --lan + langem API-Key, kein Public ohne Auth/Overlay (Tailscale/ZeroTier). Secrets via openssl rand, nie in Logs/UI.
- Tests: bash -n + Shellcheck, Install -> is-active + HTTP, qm reboot -> 60-120 s -> is-active + HTTP + onboot Check. Reboot-Log als Beleg im README.

## 6. Erfolgs- / Abnahmekriterien MVP

1. Einzeiler auf Proxmox-Host erstellt VM mit naechster freier ID + Hostname voicestudio.
2. Service active + Web UI auf http://<VM-IP>:3900 erreichbar.
3. Reboot-Test bestanden (nach Reboot wieder active + HTTP 200, Log vorhanden).
4. README mit Einzeiler + Update-/Deinstall-Hinweis + erwarteter Ausgabe.
5. Dateien: install/voicestudio.sh, systemd/voicestudio.service, README.md (Compose/.env werden im Gast erzeugt).

## 7. Offene Punkte fuer Plan-Phase

- Debian-13-Quelle final (Cloud-Image vs. Template-Storage) + qm-Flags pinnen.
- Compose-File: Upstream deploy/docker-compose.yml 1:1 oder minimale Kopie im Installer einbetten.
- LAN-Flag vs. Loopback-Default + WORKER_PORT 7443 aufnehmen oder weglassen.
- GPU_PROFILE nvidia/rocm: nur Flag + Check im MVP oder gleich voll verkabeln.

Spec Self-Review: keine TBD/TODO, konsistent mit freigegebenem Design (A + GPU-Flag, :stable, API-Key-Auto), Scope = 1 MVP (VM CPU + vorbereitetes GPU-Flag), keine Mehrdeutigkeit bei ID/Hostname/Ports/Verifikation offengelassen.

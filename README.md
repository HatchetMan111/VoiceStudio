# VoiceStudio auf Proxmox (VM) – Einzeiler-Installation

> **Hinweis: Das ist NICHT das VoiceStudio-App-Repository.**
> Dieses Repo enthaelt **nur den Proxmox-Installer** fuer VoiceStudio — keinen App-Code.
> Die Anwendung liegt bei Upstream:
> `https://github.com/debpalash/VoiceStudio` (AGPL-3.0-only).
> Das Install-Script nutzt deren offizielles Docker-Image
> (`ghcr.io/debpalash/voicestudio:stable`) — alles laeuft vollstaendig lokal.

VoiceStudio (Open-Source ElevenLabs-Alternative: Clonen, Designen, Dubben,
Diktieren, Transkribieren) laeuft in einer Debian-13-VM mit Docker Compose:
Web UI auf Port **3900**, systemd-Service mit `Restart=always`, VM mit `onboot: 1`.

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `voicestudio` |
| Zweck | Lokale Sprachsynthese / Voice-Cloning / Dubbing |
| Tech-Stack | Python/FastAPI (Docker) – Upstream-Image |
| Upstream-Repo | `https://github.com/debpalash/VoiceStudio` |
| Web UI | `http://<VM-IP>:3900`, bind `0.0.0.0` im Gast, Host-Mapping Loopback-Default |
| Standard-Ressourcen | 4 vCPU / 8192 MB RAM / 30 GB Disk (Minimum — 2,4–4 GB Models) |
| VM-ID | immer die **naechste freie ID** (`pvesh get /cluster/nextid`), ausser `--vmid` gesetzt |
| Arch | nur `amd64` (Upstream-Image ist `linux/amd64`-only) |

## 1. Installation (Einzeiler, auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/VoiceStudio/main/install/voicestudio.sh)"
```

> Stand: Initial-Commit mit Spec + Skeleton. Das vollstaendige
> `install/voicestudio.sh` folgt im naechsten Schritt (siehe `docs/`).
> Einzeiler oben ist der Ziel-Zustand.

## 2. Rechtliches / Attribution

- Installer-Scripte + Unit in diesem Repo: MIT (siehe `LICENSE`).
- VoiceStudio-App + Image: Upstream `debpalash/VoiceStudio`, AGPL-3.0-only;
  Modelle mit eigenen Lizenzen (vor kommerzieller Nutzung pruefen).
- Kein Fork, kein kopierter Upstream-Code — nur Referenz per Image + Link.
- Voice-Cloning nur mit Einwilligung. Keine Secrets im Repo (`.env`,
  API-Keys, Tokens werden zur Laufzeit generiert, nie committet).

## 3. Dateien

```text
VoiceStudio/                    # dieses Repo: NUR Proxmox-Installer
├── install/voicestudio.sh      # (folgt) Proxmox-Install-Script, set -euo pipefail, idempotent
├── systemd/voicestudio.service # systemd-Unit (Restart=always, After=network-online.target + docker.service)
├── docs/                       # Design-Spec
└── README.md                   # diese Datei
```

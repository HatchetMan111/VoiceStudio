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

Einfach kopieren und auf dem Proxmox-Host als `root` einfügen
(Community-Scripts-Stil, keine weitere Datei nötig):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/VoiceStudio/main/install/voicestudio.sh)"
```

Anpassungen wahlweise per Umgebungsvariable oder Flag:

```bash
VM_ID=101 CORES=8 RAM=16384 DISK=40 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/VoiceStudio/main/install/voicestudio.sh)"
bash voicestudio.sh --vmid 101 --cores 8 --memory 16384 --disk 40 --bridge vmbr0 --storage local --tag stable
bash voicestudio.sh --vmid 101 --lan   # Port 3900 zusätzlich im LAN freigeben (mit API-Key)
bash voicestudio.sh --debug   # = bash -x, maximale Fehlermeldungskette
```

Das Skript (`set -euo pipefail`, idempotent):
1. prüft Host/Tools (qm, pvesh, ssh, amd64), nimmt die nächste freie VM-ID,
   erkennt dateibasierten Storage (bevorzugt `local`), lädt das
   Debian-13-Cloud-Image einmalig nach `/var/tmp` (SHA512-Prüfung wenn möglich),
2. erstellt die VM `voicestudio` (`onboot: 1`, qemu-guest-agent, cloud-init,
   DHCP, SSH-Key-Login), startet sie und ermittelt die Gast-IP,
3. installiert im Gast Docker + Compose-Plugin (Debian-Pakete), legt
   `/opt/voicestudio/` (`docker-compose.yml` + `.env` mit zufälligem
   `OMNIVOICE_API_KEY`) an, schreibt die systemd-Unit,
   `systemctl enable --now voicestudio`,
4. verifiziert `systemctl is-active voicestudio` + HTTP auf
   `127.0.0.1:3900/health` und gibt die finale URL + VM-IP aus.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active voicestudio = active).
[OK]    Web UI antwortet (HTTP 200 auf localhost:3900/health).
[OK]    VM startet automatisch (onboot: 1).

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : VoiceStudio – Open-Source Voice-Studio (Upstream: debpalash/VoiceStudio, AGPL-3.0)
  VM           : 100 (Hostname: voicestudio, onboot=1)
  Ressourcen   : 4 vCPU / 8192 MB RAM / 30 GB Disk
  Web UI       : http://127.0.0.1:3900 (im Gast; Tunnel: ssh -L 3900:127.0.0.1:3900 root@192.168.1.100)
  ...
```

Hinweis Loopback-Default: Port 3900 ist per Default nur im Gast auf
`127.0.0.1` gebunden. UI entweder per `--lan`-Re-Run freigeben
(`bash voicestudio.sh --vmid 100 --lan`, API-Key im UI eingeben) oder per
SSH-Tunnel öffnen: `ssh -L 3900:127.0.0.1:3900 root@<VM-IP>`, dann
`http://localhost:3900`.

## 2. Reboot-Test (Reboot-sicher belegen)

```bash
VM=100; KEY=/root/.ssh/voicestudio_proxmox
qm reboot $VM
sleep 120  # Erster Start nach Reboot: Image + Modelle brauchen Zeit
ssh -i $KEY root@$(qm guest cmd $VM network-get-interfaces | python3 -c 'import json,sys
for i in json.load(sys.stdin):
  [print(a["ip-address"]) or exit() for a in i.get("ip-addresses",[]) if a.get("ip-address-type")=="ipv4" and not a["ip-address"].startswith("127.")]') 'systemctl is-active voicestudio && curl -fs http://127.0.0.1:3900/health'
qm config $VM | grep -i onboot   # muss: onboot: 1
```

## 3. Update (idempotent – mit --vmid erneut laufen lassen)

```bash
bash voicestudio.sh --vmid 100
# aktualisiert Compose/Unit (Secrets bleiben), pull + restart, danach Verifikation
```

## 4. Deinstallation

```bash
qm stop 100 && qm destroy 100
```

## 5. Debugging (komplette Fehlermeldungskette)

- Jeder Lauf loggt **stdout+stderr vollständig** nach `/tmp/voicestudio-install-<Datum>.log`.
- Bei Fehlern druckt das Skript: Befehl, Zeile, Exit-Code, Stacktrace
  (`caller`), `qm config`/`qm status`, Gast-`journalctl`/`docker ps`/
  `compose logs` — niemals nur die letzte Zeile.
- Re-Run mit Trace: `bash -x voicestudio.sh --vmid 100`.

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
├── install/voicestudio.sh      # Proxmox-Install-Script (Community-Scripts-konform, Variablen oben)
├── systemd/voicestudio.service # systemd-Unit (Restart=always, After=network-online.target + docker.service)
├── docs/                       # Design-Spec
└── README.md                   # diese Datei
```

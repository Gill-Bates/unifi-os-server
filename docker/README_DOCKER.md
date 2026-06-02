<p align="center">
  <img
    src="https://cdn.prod.website-files.com/622b70d8906c7ab0c03f77f8/69a26cf6852702887e7150f0_63b40a92093c6b2f3767e4e6_tMCv8T-y_400x400.png"
    alt="UniFi Logo"
    width="140"
    style="border-radius:24px;"
  >
</p>

<p align="center">
  <a href="https://github.com/Gill-Bates/unifi-os-server/releases">
    <img src="https://img.shields.io/github/v/tag/Gill-Bates/unifi-os-server?label=version&color=blue" alt="Latest Version">
  </a>
  <a href="https://github.com/Gill-Bates/unifi-os-server/actions/workflows/docker-build.yml">
    <img src="https://github.com/Gill-Bates/unifi-os-server/actions/workflows/docker-build.yml/badge.svg" alt="Docker Build">
  </a>
  <a href="https://github.com/Gill-Bates/unifi-os-server/actions/workflows/check-updates.yml">
    <img src="https://github.com/Gill-Bates/unifi-os-server/actions/workflows/check-updates.yml/badge.svg" alt="Check Updates">
  </a>
  <a href="https://hub.docker.com/r/giiibates/unifi-os-server">
    <img src="https://img.shields.io/docker/pulls/giiibates/unifi-os-server" alt="Docker Pulls">
  </a>
</p>

# UniFi OS Server

Unofficial Docker image for running **UniFi OS Server** with Docker Compose.

This image is built from the official UniFi OS Server software distributed by Ubiquiti. The build extracts the internal `uosserver` image from the official installer and wraps it into a Docker runtime image.

## Tags

| Tag | Description |
|---|---|
| `latest` | Latest published UniFi OS Server image |
| `<version>` | Versioned multi-architecture image |
| `<version>-amd64` | amd64 image |
| `<version>-arm64` | arm64 image |

Supported platforms:

- `linux/amd64`
- `linux/arm64`

## Quick Start

Create persistent data directories:

```bash
mkdir -p data/{persistent,var-log,data,srv,var-lib-unifi,var-lib-postgresql,var-lib-mongodb,etc-rabbitmq-ssl}
```

Example `docker-compose.yaml`:

```yaml
services:
  unifi-os-server:
    image: giiibates/unifi-os-server:latest
    container_name: unifi-os-server
    restart: unless-stopped
    cgroup: host
    stop_signal: SIGRTMIN+3

    cap_add:
      - NET_RAW
      - NET_ADMIN

    environment:
      - UOS_SYSTEM_IP=unifi.example.com

    ports:
      - "11443:443/tcp"
      - "8080:8080/tcp"
      - "8443:8443/tcp"
      - "3478:3478/udp"
      - "10003:10003/udp"

    tmpfs:
      - /run:exec
      - /run/lock
      - /tmp:exec
      - /var/lib/journal
      - /var/opt/unifi/tmp:size=64m

    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
      - ./data/persistent:/persistent
      - ./data/var-log:/var/log
      - ./data/data:/data
      - ./data/srv:/srv
      - ./data/var-lib-unifi:/var/lib/unifi
      - ./data/var-lib-postgresql:/var/lib/postgresql
      - ./data/var-lib-mongodb:/var/lib/mongodb
      - ./data/etc-rabbitmq-ssl:/etc/rabbitmq/ssl
```

Start:

```bash
docker compose up -d
```

Open:

```text
https://<your-host>:11443
```

> **Note:** The GUI uses a self-signed certificate. Accept the browser security warning on first access.

> **First boot:** All services take 3–5 minutes to initialize. Monitor progress with `docker logs -f unifi-os-server`.

## Important Environment Variables

### `UOS_SYSTEM_IP`

Set this to the hostname or IP address that UniFi devices should use to reach the server. Required for device adoption.

```yaml
environment:
  - UOS_SYSTEM_IP=192.168.1.10
```

### `HARDWARE_PLATFORM`

Optional. Set to `synology` when running on Synology NAS hardware that is not automatically detected.

```yaml
environment:
  - HARDWARE_PLATFORM=synology
```

## Ports

| Port | Protocol | Required | Purpose |
|---:|:---:|:---:|---|
| `443` / `11443` | TCP | ✔ | UniFi OS web interface |
| `8080` | TCP | ✔ | Device and application communication |
| `8443` | TCP | ✔ | UniFi Network Application GUI/API |
| `3478` | UDP | ✔ | STUN / device adoption |
| `10003` | UDP | ✔ | Device discovery |
| `8444` | TCP | | Hotspot portal (SSL) |
| `6789` | TCP | | Mobile speed test |
| `9543` | TCP | | UniFi Identity Hub |
| `11084` | TCP | | UniFi Site Supervisor |
| `5671` | TCP | | AMQPS |
| `8880` | TCP | | Hotspot portal redirect (HTTP) |
| `8881` | TCP | | Hotspot portal redirect |
| `8882` | TCP | | Hotspot portal redirect |
| `5514` | UDP | | Remote syslog |
| `5005` | TCP | | RTP |

## Updating

```bash
docker compose pull
docker compose up -d
```

Persistent data under `./data` remains intact.

## Troubleshooting

```bash
# Live container log (systemd + all services)
docker logs -f unifi-os-server

# Service startup status
docker exec -it unifi-os-server systemctl list-jobs

# Active network listeners
docker exec -it unifi-os-server ss -tulpn

# UniFi core service log
docker exec -it unifi-os-server journalctl -u unifi-core -f

# PostgreSQL log
docker exec -it unifi-os-server journalctl -u postgresql -f
```

## Security Notice

Trivy or other scanners may report **HIGH** or **CRITICAL** vulnerabilities.

This image contains official upstream UniFi OS Server components from Ubiquiti. Many vulnerabilities must be fixed by Ubiquiti in a future upstream release before they can be included here.

## Disclaimer

This project is not affiliated with, endorsed by, or sponsored by Ubiquiti Inc.

UniFi and Ubiquiti are trademarks or registered trademarks of Ubiquiti Inc.

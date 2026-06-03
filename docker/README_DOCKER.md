<p align="center">
  <img
    src="https://cdn.prod.website-files.com/622b70d8906c7ab0c03f77f8/69a26cf6852702887e7150f0_63b40a92093c6b2f3767e4e6_tMCv8T-y_400x400.png"
    alt="UniFi Logo"
    width="180"
    style="border-radius: 24px;"
  >
</p>

<h1 align="center">UniFi OS Server for Docker Compose</h1>

---

<p align="center">
  Run UniFi OS Server in a Docker container with persistent storage, systemd support, and multi-architecture images.
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
<p align="center">
Unofficial Docker image for running <strong>UniFi OS Server</strong> with Docker Compose.<br>
Built from the official UniFi OS Server software distributed by Ubiquiti — the internal <code>uosserver</code> image is extracted from the official installer and wrapped into a Docker runtime image.
</p>

---

## Tags

<details>
<summary><strong>Available tags and supported platforms</strong></summary>

<br>

| Tag | Description |
|---|---|
| `latest` | Latest published multi-architecture image |
| `<version>` | Versioned multi-architecture image (e.g. `5.1.15`) |

Supported platforms:

- `linux/amd64`
- `linux/arm64`

> Architecture-specific tags (`<version>-amd64`, `<version>-arm64`) are used only as intermediate build artifacts and are removed from Docker Hub after the multi-arch manifest is created.

</details>

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
      UOS_SYSTEM_IP: ${UOS_SYSTEM_IP:-}
      UOS_SHOW_JOURNAL: ${UOS_SHOW_JOURNAL:-false}
      HARDWARE_PLATFORM: ${HARDWARE_PLATFORM:-}

    ports:
      - "11443:443"
      - "8080:8080"
      - "8443:8443"
      - "8444:8444"
      - "3478:3478/udp"
      - "10003:10003/udp"
      - "5514:5514/udp"
      - "5671:5671"
      - "5005:5005"
      - "6789:6789"
      - "8880:8880"
      - "8881:8881"
      - "8882:8882"
      - "9543:9543"
      - "11084:11084"

    tmpfs:
      - /run:exec
      - /run/lock
      - /tmp:exec
      # journald uses /run/log/journal with Storage=volatile
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
  UOS_SYSTEM_IP: 192.168.1.10
```

### `HARDWARE_PLATFORM`

Optional. Set to `synology` when running on Synology NAS hardware that is not automatically detected.

```yaml
environment:
  HARDWARE_PLATFORM: synology
```

## Ports

<details>
<summary><strong>Full port reference</strong></summary>

<br>

| Port | Protocol | Required | Purpose |
|---:|:---:|:---:|---|
| `443` / `11443` | TCP | ✔ | UniFi OS web interface |
| `8080` | TCP | ✔ | Device and application communication |
| `3478` | UDP | ✔ | STUN / device adoption |
| `10003` | UDP | ✔ | Device discovery |
| `8443` | TCP | | UniFi Network Application GUI/API |
| `8444` | TCP | | Hotspot portal (SSL) |
| `5514` | UDP | | Remote syslog |
| `5671` | TCP | | AMQPS |
| `5005` | TCP | | RTP |
| `6789` | TCP | | Mobile speed test |
| `8880` | TCP | | Hotspot portal redirect (HTTP) |
| `8881` | TCP | | Hotspot portal redirect |
| `8882` | TCP | | Hotspot portal redirect |
| `9543` | TCP | | UniFi Identity Hub |
| `11084` | TCP | | UniFi Site Supervisor |

</details>

## Updating

```bash
docker compose pull
docker compose up -d
```

Persistent data under `./data` remains intact.

## Troubleshooting

```bash
# Live container log (startup banner by default)
docker logs -f unifi-os-server

# Service startup status
docker exec -it unifi-os-server systemctl list-jobs

# Show all service states
docker exec -it unifi-os-server systemctl list-units --type=service

# Active network listeners
docker exec -it unifi-os-server ss -tulpn

# UniFi core service log
docker exec -it unifi-os-server journalctl -u unifi-core -f

# UniFi Network application log
docker exec -it unifi-os-server journalctl -u unifi -f

# PostgreSQL log
docker exec -it unifi-os-server journalctl -u postgresql -f

# RabbitMQ log
docker exec -it unifi-os-server journalctl -u rabbitmq-server -f
```

> By default, `docker logs -f` shows only the startup banner and entrypoint summary. Set `UOS_SHOW_JOURNAL=true` to forward the full systemd journal to Docker logs. Otherwise, use `docker exec ... journalctl` for verbose service logs.

## Security Notice

Trivy or other scanners may report **HIGH** or **CRITICAL** vulnerabilities.

This image contains official upstream UniFi OS Server components from Ubiquiti. Many vulnerabilities must be fixed by Ubiquiti in a future upstream release before they can be included here.

## Disclaimer

This project is not affiliated with, endorsed by, or sponsored by Ubiquiti Inc.

UniFi and Ubiquiti are trademarks or registered trademarks of Ubiquiti Inc.

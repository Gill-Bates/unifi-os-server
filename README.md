# UniFi OS Server Docker

[![Docker Build](https://github.com/giiibates/unifi-os-server/actions/workflows/docker-build.yml/badge.svg)](https://github.com/giiibates/unifi-os-server/actions/workflows/docker-build.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/giiibates/unifi-os-server)](https://hub.docker.com/r/giiibates/unifi-os-server)

Run [UniFi OS Server](https://blog.ui.com/article/introducing-unifi-os-server) directly in Docker.

This project extracts the inner `uosserver` image from the official Ubiquiti installer and runs systemd directly - no nested Podman containers.

## Quick Start

```bash
docker pull giiibates/unifi-os-server:latest

# Create data directories
mkdir -p data/{persistent,var-log,data,srv,var-lib-unifi,var-lib-mongodb,etc-rabbitmq-ssl}

# Start with docker compose
docker compose up -d
```

See [docker-compose.yaml](docker-compose.yaml) for the full configuration.

## Why This Approach?

The official UniFi OS Server installer is designed for bare-metal Linux with systemd. It:
1. Creates a `uosserver` user
2. Loads an embedded OCI image (`uosserver:0.0.54`) into Podman
3. Starts a nested Podman container with `pasta` networking

This nested approach doesn't work well in Docker. Instead, we:
1. **Extract** the inner `uosserver` image from the installer
2. **Run systemd directly** (no Podman-in-Docker)
3. **Use Docker's networking** instead of pasta

The result is a clean, reproducible image that runs the official UniFi OS services.

## Supported Architectures

| Architecture | Tag |
|--------------|-----|
| x86_64 (amd64) | `giiibates/unifi-os-server:latest` |

Currently amd64-only.

## Building Release Images

```bash
# Required: Set the installer URL
export UNIFI_OS_URL_X64="https://fw-download.ubnt.com/data/unifi-os-server/...-x64"

# Build and push
./docker/build.sh

# Or build locally without pushing
PUSH=false ./docker/build.sh
```

The build process:
1. Builds an extractor image with Podman
2. Runs the Ubiquiti installer (fails at container start, but extracts the image)
3. Exports the `uosserver` image from Podman storage
4. Builds a runtime image with our entrypoint
5. Optionally validates the image starts correctly

### Environment Variables for Build

| Variable | Default | Description |
|----------|---------|-------------|
| `UNIFI_OS_URL_X64` | - | Installer URL (required) |
| `IMAGE_NAME` | `giiibates/unifi-os-server` | Target image name |
| `VERSION` | from URL | Version tag |
| `PUSH` | `true` | Push to registry |
| `SKIP_VALIDATION` | `false` | Skip runtime validation |

## Runtime Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `UOS_SYSTEM_IP` | - | Hostname/IP for device adoption |
| `HARDWARE_PLATFORM` | - | Set to `synology` for Synology NAS |
| `UOS_UUID` | auto | Custom UUID (persisted to /data/uos_uuid) |

### Required Container Settings

The container requires these settings for systemd:

```yaml
cgroup: host
cap_add:
  - NET_RAW
  - NET_ADMIN
tmpfs:
  - /run:exec
  - /run/lock
  - /tmp:exec
  - /var/lib/journal
volumes:
  - /sys/fs/cgroup:/sys/fs/cgroup:rw
stop_signal: SIGRTMIN+3
```

## Ports

| Protocol | Port | Direction | Usage |
|----------|------|-----------|-------|
| TCP | 11443 | Ingress | UniFi OS Server GUI/API |
| TCP | 8080 | Ingress | Device communication (required) |
| TCP | 8443 | Ingress | UniFi Network Application GUI/API |
| UDP | 3478 | Both | STUN for device adoption (required) |
| UDP | 10003 | Ingress | Device discovery (required) |
| TCP | 5005 | Ingress | RTP control |
| TCP | 9543 | Ingress | UniFi Identity Hub |
| TCP | 6789 | Ingress | Mobile speed test |
| TCP | 8444 | Ingress | Hotspot portal (HTTPS) |
| UDP | 5514 | Ingress | Remote syslog |
| TCP | 11084 | Ingress | Site Supervisor |
| TCP | 5671 | Ingress | AMQPS |
| TCP | 8880-8882 | Ingress | Hotspot portal (HTTP) |

## Device Adoption

To adopt devices, set `UOS_SYSTEM_IP` to your server's hostname or IP:

```yaml
environment:
  - UOS_SYSTEM_IP=unifi.example.com
```

Then SSH into each device and run:
```bash
set-inform http://$UOS_SYSTEM_IP:8080/inform
```

## Acknowledgments

Inspired by [lemker/unifi-os-server](https://github.com/lemker/unifi-os-server).

## License

See [LICENSE](LICENSE).
| TCP | 8443 | Ingress | UniFi Network Application GUI/API |
| TCP | 8444 | Ingress | Secure Portal for Hotspot |
| UDP | 3478 | Both | STUN for device adoption and communication (also required for Remote Management) |
| UDP | 5514 | Ingress | Remote syslog capture |
| UDP | 10003 | Ingress | Device discovery during adoption |
| TCP | 11084 | Ingress | UniFi Site Supervisor |
| TCP | 5671 | Ingress | AQMPS |
| TCP | 8880 | Ingress | Hotspot portal redirection (HTTP) |
| TCP | 8881 | Ingress | Hotspot portal redirection (HTTP) |
| TCP | 8882 | Ingress | Hotspot portal redirection (HTTP) |

## License

See [LICENSE](LICENSE) file.
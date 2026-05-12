# UniFi OS Server Docker

[![Docker Build](https://github.com/giiibates/unifi-os-server/actions/workflows/docker-build.yml/badge.svg)](https://github.com/giiibates/unifi-os-server/actions/workflows/docker-build.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/giiibates/unifi-os-server)](https://hub.docker.com/r/giiibates/unifi-os-server)

Run UniFi OS Server in Docker with multi-architecture support (amd64 & arm64).

## Quick Start

```bash
docker pull giiibates/unifi-os-server:latest
docker compose up -d
```

## Supported Architectures

| Architecture | Tag |
|--------------|-----|
| x86_64 (amd64) | `giiibates/unifi-os-server:latest` |
| ARM64 (aarch64) | `giiibates/unifi-os-server:latest` |

The image automatically selects the correct architecture.

## Building Locally

### Using build.sh (recommended)

```bash
# Build and push (default)
./build.sh

# Build specific version
VERSION=5.0.6 ./build.sh

# Build locally without pushing
PUSH=false ./build.sh
```

### Manual buildx

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t giiibates/unifi-os-server:latest \
  --push .
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `UOS_SYSTEM_IP` | - | System IP/hostname for device adoption |
| `UOS_INSTALL_ON_BOOT` | `1` | Auto-install on first boot |
| `UOS_FORCE_INSTALL` | `0` | Force reinstall |
| `UOS_NETWORK_MODE` | `pasta` | Container network mode |
| `UOS_WEB_PORT` | `8443` | Web interface port |
| `UOS_UID` | `1000` | User ID for uosserver |
| `HARDWARE_PLATFORM` | - | Set to `synology` for Synology NAS |

## Ports

| Protocol | Port | Direction | Usage |
|----------|------|-----------|-------|
| TCP | 11443 | Ingress | UniFi OS Server GUI/API |
| TCP | 5005 | Ingress | RTP (Real-time Transport Protocol) control protocol |
| TCP | 9543 | Ingress | UniFi Identity Hub |
| TCP | 6789 | Ingress | UniFi mobile speed test |
| TCP | 8080 | Ingress | Device and application communication |
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
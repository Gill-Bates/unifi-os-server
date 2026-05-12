# UniFi OS Server Docker

[![Docker Build](https://github.com/giiibates/unifi-os-server/actions/workflows/docker-build.yml/badge.svg)](https://github.com/giiibates/unifi-os-server/actions/workflows/docker-build.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/giiibates/unifi-os-server)](https://hub.docker.com/r/giiibates/unifi-os-server)

Run UniFi OS Server in Docker with multi-architecture support (amd64 & arm64).
The published image is preinstalled during the maintainer build and does not download the upstream installer on first boot.

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

## Building Release Images

### Using build.sh (recommended)

```bash
# 1. Put the upstream installer URLs into setup.conf
# 2. Log in once
docker login

# 3. Build, preinstall, and push
./build.sh

# Optional: override the tag that is otherwise derived from the amd64 URL
VERSION=5.0.6 ./build.sh

# Optional: keep the arch-specific images only in the local Docker daemon
PUSH=false ./build.sh
```

`build.sh` does the full release flow automatically:

1. Reads the amd64 and arm64 installer URLs from `setup.conf`
2. Builds a base image for each platform
3. Starts a privileged install container per architecture
4. Waits for the UniFi installation to finish
5. Commits the installed filesystem into final runtime images
6. Pushes arch tags and a multi-arch manifest

The upstream installer binary is used only during the build container phase and is not part of the final published image.

Important: preinstalling an architecture must happen on a native runner for that architecture. The upstream installer starts rootless Podman internally, and the arm64 path fails under QEMU/binfmt emulation with `cannot clone: Invalid argument`. For reliable multi-arch releases, run `linux/amd64` on an amd64 runner and `linux/arm64` on a native arm64 runner, then publish the manifest from those pushed arch tags.

### Base Image Only

```bash
docker buildx build \
  --platform linux/amd64 \
  -t giiibates/unifi-os-server:base-test \
  .
```

This path builds only the installer-capable base image. It does not create the preinstalled runtime image that end users should pull.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `UOS_SYSTEM_IP` | - | System IP/hostname for device adoption |
| `UOS_INSTALL_ON_BOOT` | `0` in published images | Published images skip installer bootstrapping |
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
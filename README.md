# UniFi OS Server Docker

[![Docker Build](https://github.com/giiibates/unifi-os-server/actions/workflows/docker-build.yml/badge.svg)](https://github.com/giiibates/unifi-os-server/actions/workflows/docker-build.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/giiibates/unifi-os-server)](https://hub.docker.com/r/giiibates/unifi-os-server)

Run UniFi OS Server in Docker with amd64 support.
The published image is preinstalled during the maintainer build and does not download the upstream installer on first boot.

## Quick Start

```bash
docker pull giiibates/unifi-os-server:latest
docker compose -f docker/docker-compose.yml up -d
```

The runtime compose file lives in [docker/docker-compose.yml](/opt/unifi-os-server/docker/docker-compose.yml).

## Supported Architectures

| Architecture | Tag |
|--------------|-----|
| x86_64 (amd64) | `giiibates/unifi-os-server:latest` |

The published image is currently amd64-only.

## Building Release Images

### Using build.sh (recommended)

```bash
# 1. Export the upstream installer URL
export UNIFI_OS_URL_X64="https://fw-download.ubnt.com/data/unifi-os-server/...-x64"

# Optional: keep arm64 URL beside it for later use
export UNIFI_OS_URL_ARM64="https://fw-download.ubnt.com/data/unifi-os-server/...-arm64"

# 2. Log in once
docker login

# 3. Build, preinstall, and push for the native host architecture
./build.sh

# Optional: override the tag that is otherwise derived from the amd64 URL
VERSION=5.0.6 ./build.sh

# Optional: keep the arch-specific image only in the local Docker daemon
PUSH=false ./build.sh

# Optional: override the platform explicitly
PLATFORMS=linux/amd64 ./build.sh
```

`build.sh` does the full release flow automatically:

1. Reads the amd64 installer URL from `UNIFI_OS_URL_X64`
2. Builds a base image for the requested native platform
3. Starts a privileged install container for that architecture
4. Waits for the UniFi installation to finish
5. Commits the installed filesystem into final runtime images
6. Pushes the architecture tag plus `:version` and `:latest`

The upstream installer binary is used only during the build container phase and is not part of the final published image.

If you want to keep the exports in a file locally, you can put them into [setup.conf](/opt/unifi-os-server/setup.conf) and load them with `source setup.conf` before running `./build.sh`.

Important: the active release path is currently amd64-only. Run the build on an amd64 host or runner.

### Base Image Only

```bash
docker buildx build \
  --platform linux/amd64 \
  -f docker/Dockerfile \
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
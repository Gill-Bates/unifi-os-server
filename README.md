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

# UniFi OS Server with Docker Compose

This guide is written from an end-user perspective. If you want to run UniFi OS Server, you will usually only need [docker-compose.yaml](/opt/unifi-os-server/docker-compose.yaml). 🚀

## Requirements

- Docker Engine with `docker compose`
- A Linux host
- Free ports for UniFi OS Server

## Quick Start

1. Change into the project directory.
2. Create the persistent data directories:

```bash
mkdir -p data/{persistent,var-log,data,srv,var-lib-unifi,var-lib-mongodb,etc-rabbitmq-ssl}
```

3. Update `UOS_SYSTEM_IP` in [docker-compose.yaml](/opt/unifi-os-server/docker-compose.yaml).

Example:

```yaml
environment:
  - UOS_SYSTEM_IP=unifi.example.com
```

4. Start the container:

```bash
docker compose up -d
```

5. UniFi OS Server will then be available at `https://<your-host>:11443`.

## What the Compose file already handles

[docker-compose.yaml](/opt/unifi-os-server/docker-compose.yaml) already includes the required runtime settings. In normal use, you should not need to add anything else. ✅

- `cgroup: host` for systemd inside the container
- `NET_RAW` and `NET_ADMIN` capabilities
- `tmpfs` mounts for runtime directories
- persistent data directories under `./data/...`
- the correct `stop_signal` for clean shutdowns

If you remove these settings, UniFi OS Server may no longer start or shut down correctly.

## Important Settings

### `UOS_SYSTEM_IP`

Set this to the hostname or IP address that controllers and UniFi devices should use to reach your server.

### `HARDWARE_PLATFORM`

If you are running on Synology, you can enable the prepared line in [docker-compose.yaml](/opt/unifi-os-server/docker-compose.yaml):

```yaml
- HARDWARE_PLATFORM=synology
```

## Ports

The port mappings are already defined in [docker-compose.yaml](/opt/unifi-os-server/docker-compose.yaml). The most important ones are:

- `11443/tcp` for the UniFi OS web interface
- `8080/tcp` for device communication
- `3478/udp` for STUN and adoption
- `10003/udp` for discovery
- `8443/tcp` for the UniFi Network application

If you do not need specific optional services, you can remove unused port mappings from the Compose file.

## Updating

```bash
docker compose pull
docker compose up -d
```

## Stopping

```bash
docker compose down
```

Your persistent data in `./data/...` will remain intact. 💾

## If device adoption does not work

Check these items first:

- `UOS_SYSTEM_IP` is set correctly
- `8080/tcp` is reachable
- `3478/udp` and `10003/udp` are not blocked by a firewall or NAT

## License

See [LICENSE](/opt/unifi-os-server/LICENSE). 📄
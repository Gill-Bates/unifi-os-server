<p align="center">
  <img
    src="https://cdn.prod.website-files.com/622b70d8906c7ab0c03f77f8/69a26cf6852702887e7150f0_63b40a92093c6b2f3767e4e6_tMCv8T-y_400x400.png"
    alt="UniFi Logo"
    width="180"
    style="border-radius: 24px;"
  >
</p>

<h1 align="center">UniFi OS Server for Docker Compose</h1>

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

---

## Overview

This repository provides a Docker Compose setup for running **UniFi OS Server** on a Linux host.

The image is built from the official UniFi OS Server software distributed by Ubiquiti. The included Compose file contains the required runtime settings for systemd, persistent storage, capabilities, temporary filesystems, and exposed ports.

For normal use, start with:

```text
docker-compose.yaml
```

---

## Security Notice

> [!WARNING]
> Trivy scans may report **HIGH** or **CRITICAL** vulnerabilities in this image.
>
> This project packages the official UniFi OS Server software from Ubiquiti. Many findings originate from upstream vendor components and cannot be fixed directly in this repository.
>
> Security fixes must come from Ubiquiti upstream releases and can only be included here after a new upstream version is available.
>
> *Update Jun 10, 2026:
> We have reviewed the information you provided and discussed the findings internally with our development team. The issue has been reported to the responsible teams, and fixes for the affected packages are planned for a future UniFi OS Server release.*
---

## Requirements

- Linux host
- Docker Engine
- Docker Compose plugin
- Free host ports for UniFi OS Server
- Persistent storage for UniFi data

Check Docker Compose availability:

```bash
docker compose version
```

---

## Technical Build Flow

<details>
<summary><strong>Build flow from <code>docker/build.sh</code></strong></summary>

<br>

The build script loads configuration, resolves the official UniFi OS Server installer URLs, builds one image per requested architecture, validates the runtime image, and optionally publishes architecture images and multi-architecture manifests.

```mermaid
flowchart TD
    A["docker/build.sh"] --> B["Load configuration"]
    B --> C["Resolve installer URLs"]
    C --> D["Validate requested platforms"]
    D --> E["For each platform: amd64 / arm64"]

    subgraph ARCH_BUILD["Per-architecture build"]
        direction TB
        F["1 · Build extractor image"]
        G["2 · Run extractor container"]
        H["Run official Ubiquiti installer"]
        I["Installer imports internal uosserver image into Podman"]
        J["Export /output/uosserver.tar"]
        K["3 · Load extracted image into Docker"]
        L["Tag uosserver:version-arch"]
        M["4 · Build runtime image"]
        N["Final image: image:version-arch"]
        O["5 · Validate runtime image"]
        P["Write provenance metadata"]

        F --> G --> H --> I --> J --> K --> L --> M --> N --> O --> P
    end

    E --> ARCH_BUILD
    P --> Q{"PUSH = true?"}

    Q -->|No| R["Keep local images only"]
    Q -->|Yes| S["Push architecture images"]

    S --> T{"Single arch or multi arch?"}
    T -->|Single arch| U["Tag and push: version + latest"]
    T -->|Multi arch| V["Create and push Docker manifests: version + latest"]

    R --> W["Build complete"]
    U --> W
    V --> W
```

</details>

<details>
<summary><strong>Extraction architecture</strong></summary>

<br>

This view shows how the official Ubiquiti installer is executed inside the extractor container and how the internal <code>uosserver</code> image becomes the final runtime image.

```mermaid
flowchart TB
    subgraph HOST["Docker host / CI runner"]
        direction TB
        A["docker/build.sh"] --> B["Dockerfile.extractor"]
        B --> C["Extractor image"]

        subgraph EXTRACTOR["Extractor container"]
            direction TB
            D["Official UniFi OS Server installer"]
            E["Installer runs non-interactively"]
            F["Podman storage"]
            G["Internal uosserver image"]
            H["Exported archive: /output/uosserver.tar"]

            D --> E --> F --> G --> H
        end

        C --> EXTRACTOR
        H --> I["docker load"]
        I --> J["Extracted base image: uosserver:version-arch"]
        J --> K["Dockerfile.runtime"]
        K --> L["Runtime image: image:version-arch"]
        L --> M["Runtime validation"]
        M --> N["Push arch image"]
        N --> O["Multi-arch manifest: version + latest"]
    end
```

</details>

---

## GitHub Actions Automation

This repository includes two GitHub Actions workflows:

- `check-updates.yml`
- `docker-build.yml`

### `check-updates.yml`

- Runs on schedule and manual dispatch
- Checks the official Ubiquiti download API for a new Linux x64/arm64 release pair
- Is resilient to temporary API outages/timeouts (skips safely instead of failing the whole workflow)
- Dispatches `docker-build.yml` with a pinned release version and pinned installer URLs

### `docker-build.yml`

Manual dispatch supports these inputs:

| Input | Values | Description |
|---|---|---|
| `push` | `true` / `false` | Whether to publish images |
| `platforms` | `linux/amd64,linux/arm64` | Target architectures |
| `version` | optional | Pinned UniFi OS version |
| `url_x64` | optional | Pinned x64 installer URL |
| `url_arm64` | optional | Pinned arm64 installer URL |
| `enforce_trivy_gate` | `true` / `false` | Make Trivy findings blocking |
| `promote_latest` | `auto` / `true` / `false` | Update `:latest` and mark the GitHub release latest. `auto` promotes only unpinned builds |

**Build safety rules:**

- Build version extraction fails hard if no valid semantic version is found
- amd64 and arm64 versions must match before publishing a multi-arch manifest
- Release metadata updates normalize `name`, `draft`, and `prerelease`

**Publishing behavior in GitHub Actions:**

- Per-architecture jobs push `:<version>-amd64` and `:<version>-arm64`
- `:<version>` is created only by the manifest job after both architectures succeed
- `:latest` is updated only when `promote_latest` resolves to `true`
- Manual dispatch currently exposes only the multi-architecture platform pair

**Release notes behavior:**

- GitHub Releases include an "Official UniFi Release Notes" section
- Notes are fetched from Ubiquiti metadata + UniFi Community GraphQL data
- External note fetch calls use explicit request timeouts

**Security scan behavior:**

- Trivy always runs for `HIGH` and `CRITICAL`
- Default mode is non-blocking (`enforce_trivy_gate=false`) due to upstream vendor CVEs
- Set `enforce_trivy_gate=true` to make findings blocking

---

## Quick Start

### 1. Clone or enter the project directory

```bash
cd unifi-os-server
```

### 2. Create persistent data directories

```bash
mkdir -p data/{persistent,var-log,data,srv,var-lib-unifi,var-lib-postgresql,var-lib-mongodb,etc-rabbitmq-ssl}
```

### 3. Configure `UOS_SYSTEM_IP`

Edit `docker-compose.yaml` and set the address that UniFi devices should use to reach this server.

```yaml
environment:
  - UOS_SYSTEM_IP=unifi.example.com
```

You can use either a DNS name or an IP address.

### 4. Start UniFi OS Server

```bash
docker compose up -d
```

### 5. Open the web interface

```text
https://<your-host>:11443
```

---

## Runtime Settings

The provided `docker-compose.yaml` already includes the required runtime settings.

| Setting | Value | Why it's needed |
|---|---|---|
| `cgroup` | `host` | systemd requires access to the host cgroup hierarchy |
| `cap_add` | `NET_RAW`, `NET_ADMIN` | Required for network configuration and device adoption |
| `tmpfs` | `/run`, `/run/lock`, `/tmp`, `/var/opt/unifi/tmp` | systemd and UniFi services need writable in-memory paths at startup |
| `volumes` | `/sys/fs/cgroup:/sys/fs/cgroup:rw` | Direct cgroup mount required by systemd inside the container |
| `volumes` | `./data/...` | Persistent storage — data survives container recreation |
| `stop_signal` | `SIGRTMIN+3` | Tells systemd to shut down cleanly instead of being force-killed |

> Do not remove these settings unless you know exactly which UniFi OS component no longer needs them.

---

## Important Environment Variables

| Variable | Default | Required | Description |
|---|:---:|:---:|---|
| `UOS_SYSTEM_IP` | — | ✔ | Address (hostname or IP) that UniFi devices use to reach this server. Example: `unifi.example.com` |
| `UOS_SHOW_JOURNAL` | `false` | | Forward the full systemd journal to `docker logs`. Set to `true` for verbose service logs. |
| `UOS_UUID` | auto | | Fixed UUIDv5 identifier for this instance. Useful when the identity must survive container recreation without a persistent `/data` mount. Must match format `xxxxxxxx-xxxx-5xxx-[89ab]xxx-xxxxxxxxxxxx`. An invalid value aborts startup. |
| `HARDWARE_PLATFORM` | — | | Set to `synology` to enable Synology-specific runtime patches. Only required on Synology hardware. |

---

## Ports

The Compose file already defines the required port mappings.

Commonly used ports:

| Port | Protocol | Required | Purpose |
|---:|:---:|:---:|---|
| `11443` | TCP | ✔ | UniFi OS web interface |
| `8080` | TCP | ✔ | Device communication |
| `8443` | TCP | ✔ | UniFi Network application |
| `3478` | UDP | ✔ | STUN and adoption |
| `10003` | UDP | | Device discovery |

Optional services may expose additional ports depending on your UniFi setup. Unused optional mappings can be removed from `docker-compose.yaml`.

---

## Updating

Pull the latest image and recreate the container:

```bash
docker compose pull
docker compose up -d
```

Persistent data under `./data/...` remains intact.

---

## Stopping

Stop the container:

```bash
docker compose down
```

This does not delete persistent data.

---

## Troubleshooting

### Self-Check

The image includes a built-in diagnostic tool. Run it against a running container to get a structured summary of service states, database health, ports, disk usage, and recent errors:

```bash
docker exec -it <container_name> diagnostics
```

The tool checks:
- systemd is running as PID 1 and cgroup v2 is active
- all UniFi and supporting services (PostgreSQL, MongoDB, RabbitMQ, nginx) and their states
- required PostgreSQL databases exist
- required TCP/UDP ports are listening
- persistent volume mounts and available disk space
- UOS UUID, version file, and `system_ip` configuration
- error-level journal entries from the last 15 minutes

Exit code `0` means all checks passed. Any failure or warning produces exit code `1`.

### Device adoption does not work

Check the following:

- `UOS_SYSTEM_IP` points to the correct reachable hostname or IP address
- `8080/tcp` is reachable from the device network
- `3478/udp` is not blocked by a firewall or NAT
- `10003/udp` is available if discovery is required
- the host firewall allows the mapped ports

### Web interface is not reachable

Check container status:

```bash
docker compose ps
```

Check logs:

```bash
docker compose logs -f
```

Verify that the host port is listening:

```bash
ss -tulpen | grep 11443
```

---

## Data Persistence

Persistent data is stored below:

```text
./data/
```

Do not delete this directory unless you intentionally want to reset UniFi OS Server data.

Recommended backup target:

```text
./data/
```

---

## Disclaimer

This project is not affiliated with, endorsed by, or sponsored by Ubiquiti Inc. UniFi and Ubiquiti are trademarks or registered trademarks of Ubiquiti Inc.

---

## License

See [LICENSE](LICENSE).

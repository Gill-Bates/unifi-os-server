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
  <a href="https://github.com/Gill-Bates/unifi-os-server/releases">
    <img src="https://img.shields.io/github/v/tag/Gill-Bates/unifi-os-server?label=version&color=blue" alt="Latest Version">
  </a>
  <a href="https://github.com/Gill-Bates/unifi-os-server/actions/workflows/docker-build.yml">
    <img src="https://github.com/Gill-Bates/unifi-os-server/actions/workflows/docker-build.yml/badge.svg" alt="Docker Build">
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

## Quick Start

```bash
mkdir -p data/{persistent,var-log,data,srv,var-lib-unifi,var-lib-postgresql,var-lib-mongodb,etc-rabbitmq-ssl}
docker compose up -d
```

Open `https://<your-host>:11443` (self-signed certificate — accept the browser warning). First boot takes 3–5 minutes; follow along with `docker logs -f unifi-os-server`.

## Security Notice

Trivy or other scanners may report **HIGH**/**CRITICAL** vulnerabilities. This image packages official upstream UniFi OS Server components from Ubiquiti — such findings must be fixed upstream before they can be included here.

## Full Documentation

The complete Compose file, environment variables, port reference, updating, and troubleshooting guide live in the project README:

**[github.com/Gill-Bates/unifi-os-server](https://github.com/Gill-Bates/unifi-os-server#readme)**

## Disclaimer

This project is not affiliated with, endorsed by, or sponsored by Ubiquiti Inc. UniFi and Ubiquiti are trademarks or registered trademarks of Ubiquiti Inc.

<p align="center">
  <a href="https://www.buymeacoffee.com/tnsteinerx">
    <img src="https://img.buymeacoffee.com/button-api/?text=Buy%20me%20a%20beer&emoji=%F0%9F%8D%BA&slug=tnsteinerx&button_colour=FFDD00&font_colour=000000&font_family=Cookie&outline_colour=000000&coffee_colour=ffffff" alt="Buy Me A Coffee">
  </a>
</p>

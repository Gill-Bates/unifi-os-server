# Trixie is intentional here: the upstream installer expects Podman >= 4.9.3,
# while Debian bookworm currently ships only 4.3.1.
FROM debian:trixie-slim

# Multi-architecture support - TARGETARCH is automatically set by Docker Buildx
ARG TARGETARCH
ARG TARGETVARIANT

ARG APP_VERSION="dev"
ARG BUILD_DATE="unknown"
# Architecture-specific installer URLs from Ubiquiti
ARG UOS_INSTALLER_URL_AMD64="https://fw-download.ubnt.com/data/unifi-os-server/1856-linux-x64-5.0.6-33f4990f-6c68-4e72-9d9c-477496c22450.6-x64"
ARG UOS_INSTALLER_URL_ARM64="https://fw-download.ubnt.com/data/unifi-os-server/df5b-linux-arm64-5.0.6-f35e944c-f4b6-4190-93a8-be61b96c58f4.6-arm64"
ARG UOS_INSTALLER_CHECKSUM=""
ARG UOS_UID="1000"

LABEL org.opencontainers.image.title="unifi-os-server" \
	org.opencontainers.image.version=${APP_VERSION} \
	org.opencontainers.image.created=${BUILD_DATE} \
	org.opencontainers.image.source="https://github.com/giiibates/unifi-os-server" \
	org.opencontainers.image.description="UniFi OS Server in Docker with multi-architecture support"

# Set architecture-specific installer URL at runtime
ENV DEBIAN_FRONTEND=noninteractive \
	UOS_INSTALLER_URL_AMD64=${UOS_INSTALLER_URL_AMD64} \
	UOS_INSTALLER_URL_ARM64=${UOS_INSTALLER_URL_ARM64} \
	UOS_INSTALLER_CHECKSUM=${UOS_INSTALLER_CHECKSUM} \
	UOS_INSTALLER_PATH=/opt/uos/installer/uos-installer \
	UOS_INSTALL_ON_BOOT=1 \
	UOS_FORCE_INSTALL=0 \
	UOS_NETWORK_MODE=pasta \
	UOS_WEB_PORT=8443 \
	UOS_DATA_DIR=/var/lib/uosserver \
	UOS_CONFIG_DIR=/etc/uosserver \
	UOS_HOME=/home/uosserver \
	UOS_UID=${UOS_UID} \
	UOS_SYSTEM_IP="" \
	HARDWARE_PLATFORM=""

RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		bash \
		ca-certificates \
		curl \
		fuse-overlayfs \
		iproute2 \
		iptables \
		kmod \
		passwd \
		podman \
		procps \
		slirp4netns \
		systemd \
		tini \
		uidmap \
		util-linux \
	&& rm -rf /var/lib/apt/lists/*

RUN mkdir -p \
		/opt/uos/installer \
		/etc/containers \
		/etc/uosserver \
		/var/lib/containers/storage \
		/var/lib/uosserver \
		/var/log/uosserver \
		/home/uosserver \
		/home/uosserver/.config/containers \
		/home/uosserver/.local/share/containers/storage \
		/var/lib/systemd/linger \
	&& touch /var/lib/systemd/linger/uosserver \
	&& chown -R "${UOS_UID}:${UOS_UID}" /home/uosserver

COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=755 build/loginctl-stub.sh /usr/local/bin/loginctl
COPY --chmod=755 build/systemctl-stub.sh /usr/local/bin/systemctl

RUN mv /usr/bin/loginctl /usr/bin/loginctl.real 2>/dev/null || true \
	&& ln -sf /usr/local/bin/loginctl /usr/bin/loginctl \
	&& mv /usr/bin/systemctl /usr/bin/systemctl.real 2>/dev/null || true \
	&& ln -sf /usr/local/bin/systemctl /usr/bin/systemctl

VOLUME ["/var/lib/uosserver", "/etc/uosserver", "/var/log/uosserver"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=900s --retries=5 \
	CMD curl -fsSk https://localhost:8443/ >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD []

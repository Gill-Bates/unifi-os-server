# Trixie is intentional here: the upstream installer expects Podman >= 4.9.3,
# while Debian bookworm currently ships only 4.3.1.
FROM debian:trixie-slim@sha256:109e2c65005bf160609e4ba6acf7783752f8502ad218e298253428690b9eaa4b

ARG APP_VERSION=""
ARG BUILD_DATE=""
ARG UOS_INSTALLER_URL="https://fw-download.ubnt.com/data/unifi-os-server/1856-linux-x64-5.0.6-33f4990f-6c68-4e72-9d9c-477496c22450.6-x64"
ARG UOS_INSTALLER_FILE="1856-linux-x64-5.0.6-33f4990f-6c68-4e72-9d9c-477496c22450.6-x64"
ARG UOS_INSTALLER_CHECKSUM=""
ARG UOS_UID="1000"

LABEL org.opencontainers.image.title="unifi-os-server" \
	org.opencontainers.image.version=${APP_VERSION} \
	org.opencontainers.image.created=${BUILD_DATE}

ENV DEBIAN_FRONTEND=noninteractive \
	UOS_INSTALLER_URL=${UOS_INSTALLER_URL} \
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
		/home/uosserver/.config/containers \
		/home/uosserver/.local/share/containers/storage

COPY ${UOS_INSTALLER_FILE} ${UOS_INSTALLER_PATH}

RUN test -s "$UOS_INSTALLER_PATH" \
	&& if [ -n "$UOS_INSTALLER_CHECKSUM" ]; then echo "$UOS_INSTALLER_CHECKSUM  $UOS_INSTALLER_PATH" | sha256sum -c -; fi \
	&& chmod 755 "$UOS_INSTALLER_PATH"

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod 755 /usr/local/bin/entrypoint.sh

VOLUME ["/var/lib/uosserver", "/etc/uosserver", "/var/log/uosserver"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=5 \
	CMD curl -fsSk https://localhost:443/ >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD []

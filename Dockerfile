# syntax=docker/dockerfile:1

FROM --platform=$BUILDPLATFORM node:22-bookworm-slim AS web
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN npm ci --ignore-scripts
COPY web/ ./
RUN npm run build:static

FROM --platform=$BUILDPLATFORM golang:1.26-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
COPY --from=web /src/web/out ./server/webui/dist
ARG ARTEX_VERSION=dev
ARG TARGETOS
ARG TARGETARCH
RUN ARTEX_SKIP_FRONTEND=1 \
    ARTEX_SKIP_NPM_CI=1 \
    ARTEX_COMPRESS=0 \
    ARTEX_OUTPUT=/out/artex \
    ARTEX_BUILD_VERSION="${ARTEX_VERSION}" \
    bash ./build.sh --target "${TARGETOS:-linux}/${TARGETARCH:-amd64}"

FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS tools
ARG TARGETARCH
ARG NUCLEI_VERSION=v3.11.1
ARG HTTPX_VERSION=v1.12.0
ARG SUBFINDER_VERSION=v2.17.0
ARG KATANA_VERSION=v1.8.0
ARG FFUF_VERSION=v2.3.0
ARG DALFOX_VERSION=v3.2.4
ARG SQLMAP_VERSION=1.9.9
ARG SQLMAP_COMMIT=cceda39208b5aad478de2c3f731df4239d9881f6
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip \
    && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) PD_ARCH=amd64; FFUF_ARCH=amd64; DALFOX_ARCH=x86_64 ;; \
      arm64) PD_ARCH=arm64; FFUF_ARCH=arm64; DALFOX_ARCH=aarch64 ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    mkdir -p /out; \
    fetch() { base="$1"; asset="$2"; sums="$3"; name="$4"; \
      rm -rf /tmp/t; mkdir -p /tmp/t/x; \
      curl -fsSL "$base/$asset" -o "/tmp/t/$asset"; \
      curl -fsSL "$base/$sums" -o /tmp/t/sums.txt; \
      want="$(awk -v a="$asset" '$2 == a || $2 == "*" a { print $1 }' /tmp/t/sums.txt)"; \
      if [ -z "$want" ]; then echo "no checksum entry for $asset" >&2; exit 1; fi; \
      got="$(sha256sum "/tmp/t/$asset" | cut -d' ' -f1)"; \
      if [ "$want" != "$got" ]; then echo "checksum mismatch for $asset: want $want got $got" >&2; exit 1; fi; \
      case "$asset" in *.zip) unzip -q "/tmp/t/$asset" -d /tmp/t/x ;; *) tar -xzf "/tmp/t/$asset" -C /tmp/t/x ;; esac; \
      find /tmp/t/x -type f -name "$name" -exec install -m 0755 {} /out/ \; ; \
      [ -x "/out/$name" ] || { echo "$name not found in $asset" >&2; exit 1; }; \
      rm -rf /tmp/t; }; \
    gh="https://github.com"; \
    fetch "$gh/projectdiscovery/nuclei/releases/download/$NUCLEI_VERSION" \
      "nuclei_${NUCLEI_VERSION#v}_linux_${PD_ARCH}.zip" "nuclei_${NUCLEI_VERSION#v}_checksums.txt" nuclei; \
    fetch "$gh/projectdiscovery/httpx/releases/download/$HTTPX_VERSION" \
      "httpx_${HTTPX_VERSION#v}_linux_${PD_ARCH}.zip" "httpx_${HTTPX_VERSION#v}_checksums.txt" httpx; \
    fetch "$gh/projectdiscovery/subfinder/releases/download/$SUBFINDER_VERSION" \
      "subfinder_${SUBFINDER_VERSION#v}_linux_${PD_ARCH}.zip" "subfinder_${SUBFINDER_VERSION#v}_checksums.txt" subfinder; \
    fetch "$gh/projectdiscovery/katana/releases/download/$KATANA_VERSION" \
      "katana_${KATANA_VERSION#v}_linux_${PD_ARCH}.zip" "katana-${KATANA_VERSION#v}-checksums.txt" katana; \
    fetch "$gh/ffuf/ffuf/releases/download/$FFUF_VERSION" \
      "ffuf_${FFUF_VERSION#v}_linux_${FFUF_ARCH}.tar.gz" "ffuf_${FFUF_VERSION#v}_checksums.txt" ffuf; \
    fetch "$gh/hahwul/dalfox/releases/download/$DALFOX_VERSION" \
      "dalfox-${DALFOX_VERSION}-linux-${DALFOX_ARCH}-musl.tar.gz" "dalfox-${DALFOX_VERSION}-linux-${DALFOX_ARCH}-musl.tar.gz.sha256" dalfox; \
    git clone --quiet --depth 1 --branch "$SQLMAP_VERSION" https://github.com/sqlmapproject/sqlmap /opt/sqlmap; \
    commit="$(git -C /opt/sqlmap rev-parse HEAD)"; \
    if [ "$commit" != "$SQLMAP_COMMIT" ]; then echo "sqlmap commit mismatch: want $SQLMAP_COMMIT got $commit" >&2; exit 1; fi; \
    rm -rf /opt/sqlmap/.git

FROM python:3.12-slim-bookworm
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates ripgrep curl wget vim git jq unzip xz-utils \
      dnsutils iputils-ping netcat-openbsd inetutils-telnet whois nmap \
    && rm -rf /var/lib/apt/lists/*
ARG NODE_VERSION=22.23.4
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) NODE_ARCH=x64 ;; \
      arm64) NODE_ARCH=arm64 ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    base="https://nodejs.org/dist/v${NODE_VERSION}"; \
    asset="node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"; \
    curl -fsSL "$base/$asset" -o "/tmp/$asset"; \
    curl -fsSL "$base/SHASUMS256.txt" -o /tmp/SHASUMS256.txt; \
    want="$(awk -v a="$asset" '$2 == a { print $1 }' /tmp/SHASUMS256.txt)"; \
    if [ -z "$want" ]; then echo "no checksum entry for $asset" >&2; exit 1; fi; \
    got="$(sha256sum "/tmp/$asset" | cut -d' ' -f1)"; \
    if [ "$want" != "$got" ]; then echo "checksum mismatch for $asset: want $want got $got" >&2; exit 1; fi; \
    tar -xJf "/tmp/$asset" -C /usr/local --strip-components=1 --no-same-owner; \
    rm -f "/tmp/$asset" /tmp/SHASUMS256.txt; \
    node --version; npm --version
COPY --from=tools /out/ /usr/local/bin/
COPY --from=tools /opt/sqlmap /opt/sqlmap
RUN set -eux; \
    ln -s /opt/sqlmap/sqlmap.py /usr/local/bin/sqlmap; \
    nuclei -version >/dev/null; httpx -version; subfinder -version; katana -version; \
    ffuf -V >/dev/null; dalfox --version >/dev/null; sqlmap --version >/dev/null

ARG BBOT_VERSION=3.0.2
RUN set -eux; \
    python -m venv /opt/bbot; \
    /opt/bbot/bin/pip install --no-cache-dir "bbot==${BBOT_VERSION}"; \
    ln -s /opt/bbot/bin/bbot /usr/local/bin/bbot; \
    bbot -y --install-all-deps; \
    bbot --version >/dev/null; \
    mods="wafw00f,paramminer_getparams,lightfuzz,sslcert,gowitness"; \
    if [ "${TARGETARCH:-amd64}" = "arm64" ]; then mods="wafw00f,paramminer_getparams,lightfuzz,sslcert"; fi; \
    bbot --dry-run -t example.com -m "$mods" >/dev/null 2>&1 || true; \
    bbot --dry-run -t example.com -m "$mods" --no-color >/tmp/bbot-dry.log 2>&1 || true; \
    ! grep -qE "Installing|ERRR|CRITICAL" /tmp/bbot-dry.log || { cat /tmp/bbot-dry.log; exit 1; }

ARG PLAYWRIGHT_MCP_VERSION=0.0.83
ARG PLAYWRIGHT_CLI_VERSION=0.1.22
ARG PLAYWRIGHT_VERSION=1.64.1
RUN npm install -g "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}" "@playwright/cli@${PLAYWRIGHT_CLI_VERSION}" "playwright@${PLAYWRIGHT_VERSION}" \
    && playwright-cli --help \
    && playwright install --with-deps chromium \
    && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    if [ "${TARGETARCH:-amd64}" = "arm64" ]; then \
      pw_chrome="$(find /root/.cache/ms-playwright -type f -name chrome -path '*/chromium-*' | head -n 1)"; \
      [ -n "$pw_chrome" ] || { echo "no Playwright Chromium found" >&2; exit 1; }; \
      "$pw_chrome" --version; \
      rm -rf /root/.bbot/tools/chrome-linux; \
      mkdir -p /root/.bbot/tools/chrome-linux; \
      ln -s "$pw_chrome" /root/.bbot/tools/chrome-linux/chrome; \
    fi; \
    bbot --dry-run -t example.com -m gowitness --no-color >/tmp/bbot-gowitness.log 2>&1 || true; \
    ! grep -qE "Installing|ERRR|CRITICAL" /tmp/bbot-gowitness.log || { cat /tmp/bbot-gowitness.log; exit 1; }; \
    rm -f /tmp/bbot-gowitness.log
WORKDIR /app
COPY --from=build /out/artex /app/artex
COPY start.sh /app/start.sh
RUN chmod +x /app/artex /app/start.sh && mkdir -p /app/keys
COPY skills/ /app/skills/
VOLUME ["/app/data", "/app/keys"]
EXPOSE 8787 8788
ENTRYPOINT ["/app/start.sh"]
CMD ["-addr", ":8787", "-proxy", ":8788"]

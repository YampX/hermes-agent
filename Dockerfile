# Debian 13 still ships SQLite 3.46.1, which contains the upstream WAL-reset
# corruption bug. Build a pinned shared library for the runtime image instead
# of relying on a distro backport that trixie does not currently provide.
FROM debian:13.4 AS sqlite_build
ARG SQLITE_AUTOCONF_VERSION=3530400
ARG SQLITE_SHA256=0e9483900e92cd5de8fd48d16bf9200145a61f7fd5be542a5ac81d8a9516eb9c
RUN apt-get -o Acquire::Retries=3 update && apt-get -o Acquire::Retries=3 install -y --no-install-recommends build-essential ca-certificates curl && rm -rf /var/lib/apt/lists/* && (curl -fsSL --retry 1 --retry-all-errors --connect-timeout 15 --max-time 60 -o /tmp/sqlite.tar.gz "https://sqlite.org/2026/sqlite-autoconf-${SQLITE_AUTOCONF_VERSION}.tar.gz" || curl -fsSL --retry 3 --retry-all-errors --connect-timeout 15 --max-time 120 -o /tmp/sqlite.tar.gz "https://sources.buildroot.net/sqlite/sqlite-autoconf-${SQLITE_AUTOCONF_VERSION}.tar.gz") && printf '%s  %s\n' "${SQLITE_SHA256}" /tmp/sqlite.tar.gz > /tmp/sqlite.sha256 && sha256sum -c /tmp/sqlite.sha256 && tar -xzf /tmp/sqlite.tar.gz -C /tmp && cd "/tmp/sqlite-autoconf-${SQLITE_AUTOCONF_VERSION}" && CFLAGS="-O2 -DSQLITE_ENABLE_FTS3 -DSQLITE_ENABLE_FTS3_PARENTHESIS -DSQLITE_ENABLE_FTS4 -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_GEOPOLY -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_ENABLE_UNLOCK_NOTIFY -DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_ENABLE_DBPAGE_VTAB -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_ENABLE_PREUPDATE_HOOK -DSQLITE_ENABLE_SESSION -DSQLITE_SECURE_DELETE -DSQLITE_THREADSAFE=1 -DSQLITE_MAX_VARIABLE_NUMBER=250000" ./configure --prefix=/opt/sqlite-fixed --disable-static && make -j"$(nproc)" && make install

FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie@sha256:b3c543b6c4f23a5f2df22866bd7857e5d304b67a564f4feab6ac22044dde719b AS uv_source
FROM node:26-bookworm-slim@sha256:9e6f9357d371591e32ab6f2d8a26d63bdd0d17c29eee3f4f3e7e454d9634bf73 AS node_source
FROM debian:13.4

# --------------------------------------------------------------------------
# SIMPLIFIED RUNTIME IMAGE
#
# The previous version of this Dockerfile ran the gateway as a non-root
# "hermes" user (UID 10000), supervised by s6-overlay, with a cont-init hook
# (docker/stage2-hook.sh) that re-chowned the /opt/data data volume to that
# user on every boot. On Railway that chown never reliably took effect
# across container restarts (confirmed by direct testing: the same
# PermissionError on /opt/data/logs reproduced even when the process was
# forced to run as root), so the gateway crash-looped forever regardless of
# UID/GID env vars, pre-deploy chown commands, or root-bypass patches.
#
# This mirrors the same simple, root-only pattern used by the official
# nousresearch/hermes-agent Docker image and every working community Railway
# deployment guide: no privilege drop, no s6-overlay, no cont-init chown
# dance. tini is still used as PID 1 so MCP stdio subprocesses don't become
# zombies, but nothing else runs before the gateway starts.
# --------------------------------------------------------------------------

ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright

RUN apt-get -o Acquire::Retries=3 update && apt-get -o Acquire::Retries=3 install -y --no-install-recommends ca-certificates curl iputils-ping python3 python-is-python3 ripgrep ffmpeg gcc g++ make cmake python3-dev python3-venv libffi-dev libolm-dev libatomic1 procps git openssh-client docker-cli xz-utils tini && rm -rf /var/lib/apt/lists/*

COPY --from=sqlite_build /opt/sqlite-fixed/lib/libsqlite3.so.3.53.4 /usr/local/lib/
RUN ln -sf libsqlite3.so.3.53.4 /usr/local/lib/libsqlite3.so.0 && ln -sf libsqlite3.so.3.53.4 /usr/local/lib/libsqlite3.so && printf '/usr/local/lib\n' > /etc/ld.so.conf.d/000-sqlite-fixed.conf && ldconfig && python3 -c "import sqlite3, sys; v = sqlite3.sqlite_version_info; sys.exit(f'linked SQLite {sqlite3.sqlite_version} still has the WAL-reset bug') if v < (3, 51, 3) else None; db = sqlite3.connect(':memory:'); db.execute(\"CREATE VIRTUAL TABLE docs USING fts5(content, tokenize='trigram')\"); db.execute(\"INSERT INTO docs VALUES ('hermes')\"); sys.exit('SQLite FTS5 trigram self-test failed') if db.execute(\"SELECT count(*) FROM docs WHERE docs MATCH 'erm'\").fetchone()[0] != 1 else None; db.close()"

COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/
COPY --chmod=0755 --from=node_source /usr/local/bin/node /usr/local/bin/
COPY --from=node_source /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

WORKDIR /opt/hermes

COPY package.json package-lock.json ./
COPY web/package.json web/
COPY ui-tui/package.json ui-tui/
COPY ui-tui/packages/hermes-ink/ ui-tui/packages/hermes-ink/
COPY apps/shared/ apps/shared/

ENV npm_config_install_links=false

RUN npm install --prefer-offline --no-audit --fetch-retries=5 && for i in 1 2 3; do npx playwright install --with-deps chromium --only-shell && break || { [ "$i" = 3 ] && exit 1; echo "playwright install failed (attempt $i); retrying in 10s"; sleep 10; }; done && npm cache clean --force

COPY plugins/platforms/photon/sidecar/package.json plugins/platforms/photon/sidecar/package-lock.json plugins/platforms/photon/sidecar/patch-spectrum-mixed-attachments.mjs plugins/platforms/photon/sidecar/
RUN cd plugins/platforms/photon/sidecar && npm ci --no-audit --fetch-retries=5 && npm cache clean --force

COPY pyproject.toml uv.lock ./
RUN touch ./README.md
RUN uv sync --frozen --no-install-project --extra all --extra messaging --extra otlp --extra anthropic --extra bedrock --extra azure-identity --extra hindsight --extra matrix

COPY web/ web/
COPY ui-tui/ ui-tui/
COPY apps/shared/ apps/shared/
RUN cd web && npm run build && cd ../ui-tui && npm run build

COPY . .

RUN uv pip install --no-cache-dir --no-deps -e "."

ARG HERMES_GIT_SHA=
RUN if [ -n "${HERMES_GIT_SHA}" ]; then printf '%s\n' "${HERMES_GIT_SHA}" > /opt/hermes/.hermes_build_sha; fi

ENV HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist
ENV HERMES_TUI_DIR=/opt/hermes/ui-tui
ENV HERMES_HOME=/opt/data
ENV HERMES_WRITE_SAFE_ROOT=/opt/data
ENV HERMES_DISABLE_LAZY_INSTALLS=1
ENV HERMES_LAZY_INSTALL_TARGET=/opt/data/lazy-packages
ENV PATH="/opt/hermes/.venv/bin:/opt/data/.local/bin:${PATH}"

RUN mkdir -p /opt/data

COPY --chmod=0755 docker/entrypoint-simple.sh /opt/hermes/docker/entrypoint-simple.sh

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/opt/hermes/docker/entrypoint-simple.sh"]
CMD []

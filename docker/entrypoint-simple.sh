#!/bin/sh
# Simplified root-only entrypoint for Railway / generic Docker deploys.
#
# Replaces the s6-overlay + non-root-user + cont-init chown pipeline
# (docker/stage2-hook.sh, docker/main-wrapper.sh) that failed to reliably
# get write access to Railway persistent volumes. Everything here runs as
# root, so there is no ownership mismatch to work around: whoever mounts
# /opt/data (Railway Volume, Docker named volume, host bind-mount) just
# needs to be writable by root, which is true by default.
#
# Routing mirrors the old main-wrapper.sh contract so existing Railway/
# Docker configs keep working:
#   no args                    -> exec `hermes gateway run`
#   first arg is an executable -> exec it directly (sleep, bash, sh, ...)
#   first arg is anything else -> exec `hermes <args>` (subcommand passthrough)

set -eu

HERMES_HOME="${HERMES_HOME:-/opt/data}"

mkdir -p \
    "$HERMES_HOME/backups" \
        "$HERMES_HOME/cron" \
            "$HERMES_HOME/cron/output" \
                "$HERMES_HOME/sessions" \
                    "$HERMES_HOME/logs" \
                        "$HERMES_HOME/logs/gateways" \
                            "$HERMES_HOME/hooks" \
                                "$HERMES_HOME/memories" \
                                    "$HERMES_HOME/skills" \
                                        "$HERMES_HOME/skins" \
                                            "$HERMES_HOME/plans" \
                                                "$HERMES_HOME/workspace" \
                                                    "$HERMES_HOME/home" \
                                                        "$HERMES_HOME/pairing" \
                                                            "$HERMES_HOME/platforms/pairing" \
                                                                "$HERMES_HOME/lazy-packages"

                                                                # Seed config files on first boot only (never clobber an existing file).
                                                                seed_one() {
                                                                    dest=$1
                                                                        src=$2
                                                                            if [ ! -f "$HERMES_HOME/$dest" ] && [ -f "/opt/hermes/$src" ]; then
                                                                                    cp "/opt/hermes/$src" "$HERMES_HOME/$dest"
                                                                                        fi
                                                                                        }
                                                                                        seed_one ".env" ".env.example"
                                                                                        seed_one "config.yaml" "cli-config.yaml.example"
                                                                                        seed_one "SOUL.md" "docker/SOUL.md"

                                                                                        cd "$HERMES_HOME"

                                                                                        if [ $# -eq 0 ]; then
                                                                                            exec hermes
                                                                                            fi

                                                                                            if command -v "$1" >/dev/null 2>&1; then
                                                                                                exec "$@"
                                                                                                fi

                                                                                                exec hermes "$@"
                                                                                                

#!/bin/sh
# shellcheck shell=sh
# /opt/hermes/docker/heroku-entrypoint.sh — Heroku-specific entrypoint for
# the hermes-agent reference deployment (see HEROKU.md).
#
# Why this exists: Heroku runs containers as a random, unprivileged UID and
# ignores USER. The upstream boot path cannot tolerate that — stage2-hook.sh
# and main-wrapper.sh both hard-reject arbitrary non-root UIDs with exit 1,
# and the s6-overlay supervision tree needs root for its cont-init hooks
# (usermod/groupmod/chown). So on Heroku we skip /init and s6 entirely and
# replicate the non-privileged subset of stage2-hook.sh inline: seed the
# mutable data tree, seed config files, generate the loopback api_server
# key, run config migration and skills sync, and discover Chromium.
#
# Consequences (deliberate, for the reference experiment):
#   - No supervised services: the dashboard is exec'd directly as the web
#     process; per-profile gateway s6 slots do not exist in this runtime.
#   - /opt/data is ephemeral. Heroku discards the filesystem on every dyno
#     restart/replace and cycles dynos roughly daily. Observing exactly
#     which state disappears is the point of this deployment.
set -eu

export HERMES_HOME="${HERMES_HOME:-/opt/data}"
export HOME="$HERMES_HOME"
INSTALL_DIR=/opt/hermes

# heroku.yml's run command may arrive as our argument when Heroku honors the
# image ENTRYPOINT; drop the self-reference so both invocation styles
# (ENTRYPOINT+args and bare command) behave identically.
if [ "${1:-}" = "/opt/hermes/docker/heroku-entrypoint.sh" ]; then
    shift
fi

echo "[heroku] Starting Hermes: uid=$(id -u) PORT=${PORT:-unset} HERMES_HOME=$HERMES_HOME"

# --- Seed the mutable data tree (mirrors stage2-hook.sh's mkdir block) ---
mkdir -p \
    "$HERMES_HOME/backups" \
    "$HERMES_HOME/cron" \
    "$HERMES_HOME/sessions" \
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

# --- Seed config files on first boot (mirrors stage2-hook.sh seed_one) ---
seed_one() {
    dest=$1
    src=$2
    if [ ! -f "$HERMES_HOME/$dest" ] && [ -f "$INSTALL_DIR/$src" ]; then
        cp "$INSTALL_DIR/$src" "$HERMES_HOME/$dest"
    fi
}
seed_one "config.yaml" "cli-config.yaml.example"
seed_one "SOUL.md" "docker/SOUL.md"

# .env: real secrets come from Heroku config vars, never from a committed
# file. The .env here only carries the generated loopback api_server key —
# dyno-local and regenerated on every fresh filesystem, which is fine because
# the dashboard and gateway that share it live in the same dyno.
if [ ! -f "$HERMES_HOME/.env" ]; then
    : > "$HERMES_HOME/.env"
fi
if ! grep -q '^API_SERVER_KEY=..*' "$HERMES_HOME/.env" 2>/dev/null; then
    _gen_key=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
    if [ -n "$_gen_key" ]; then
        printf 'API_SERVER_KEY=%s\n' "$_gen_key" >> "$HERMES_HOME/.env"
        echo "[heroku] Generated API_SERVER_KEY for the loopback gateway api_server"
    fi
    unset _gen_key
fi
chmod 600 "$HERMES_HOME/.env" 2>/dev/null || true

cd "$HERMES_HOME"
# activate scripts can reference unset vars; relax -u around sourcing.
set +u
# shellcheck disable=SC1091
. "$INSTALL_DIR/.venv/bin/activate"
set -u

# --- Config-schema migration + bundled skills sync (non-fatal, as upstream) ---
if [ -f "$HERMES_HOME/config.yaml" ]; then
    python "$INSTALL_DIR/scripts/docker_config_migrate.py" \
        || echo "[heroku] Warning: docker_config_migrate.py failed; continuing" >&2
fi
if [ -d "$INSTALL_DIR/skills" ]; then
    python "$INSTALL_DIR/tools/skills_sync.py" \
        || echo "[heroku] Warning: skills_sync.py failed; continuing" >&2
fi

# --- Discover agent-browser's Chromium binary (mirrors stage2-hook.sh) ---
# No s6 container_environment here; a plain export reaches all children.
if [ -z "${AGENT_BROWSER_EXECUTABLE_PATH:-}" ] && \
        [ -n "${PLAYWRIGHT_BROWSERS_PATH:-}" ] && \
        [ -d "$PLAYWRIGHT_BROWSERS_PATH" ]; then
    browser_bin=$(find "$PLAYWRIGHT_BROWSERS_PATH" -type f \
        \( -name 'chrome' -o -name 'chromium' \
           -o -name 'chrome-headless-shell' -o -name 'headless_shell' \
           -o -name 'chromium-browser' \) \
        2>/dev/null | head -n 1)
    if [ -n "$browser_bin" ]; then
        echo "[heroku] Found agent-browser Chromium binary: $browser_bin"
        export AGENT_BROWSER_EXECUTABLE_PATH="$browser_bin"
    else
        echo "[heroku] Warning: no Chromium under $PLAYWRIGHT_BROWSERS_PATH; browser tool may fail" >&2
    fi
fi

# --- Hand off ---
# One-off dynos (`heroku run bash`, `heroku run hermes <cmd>`): pass any
# explicit command through with upstream's routing (bare executable → exec
# it; anything else → hermes subcommand).
if [ $# -gt 0 ]; then
    if command -v "$1" >/dev/null 2>&1; then
        exec "$@"
    fi
    exec hermes "$@"
fi

# Web process. HEROKU_WEB_CMD (a Heroku config var) overrides the default so
# the exposed surface can be changed without an image rebuild.
if [ -n "${HEROKU_WEB_CMD:-}" ]; then
    echo "[heroku] Starting via HEROKU_WEB_CMD override"
    exec sh -c "$HEROKU_WEB_CMD"
fi

# Default mirrors upstream's own hosted topology (see the Fly notes in
# stage2-hook.sh): the auth-gated dashboard is the single public door bound
# to Heroku's $PORT; the gateway api_server stays on loopback behind
# API_SERVER_KEY. The dashboard REQUIRES an auth provider on a non-loopback
# bind and fails closed without one.
: "${PORT:?PORT is not set — the default path is for the Heroku web process; set HEROKU_WEB_CMD for other uses}"
if [ -z "${HERMES_DASHBOARD_BASIC_AUTH_USERNAME:-}" ] && \
        [ -z "${HERMES_DASHBOARD_OAUTH_CLIENT_ID:-}" ]; then
    echo "[heroku] WARNING: no dashboard auth provider configured." >&2
    echo "[heroku]   Set HERMES_DASHBOARD_BASIC_AUTH_USERNAME + HERMES_DASHBOARD_BASIC_AUTH_PASSWORD" >&2
    echo "[heroku]   (or HERMES_DASHBOARD_OAUTH_CLIENT_ID) as Heroku config vars." >&2
    echo "[heroku]   The dashboard fails closed on a public bind without one." >&2
fi
exec hermes dashboard --host 0.0.0.0 --port "$PORT" --no-open

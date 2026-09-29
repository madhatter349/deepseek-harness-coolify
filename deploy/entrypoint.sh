#!/usr/bin/env bash
# DeepSeek Harness container entrypoint.
#
# Responsibilities:
#   1. Prepare the persistent layout under /data.
#   2. Seed the env-driven OpenAI-compatible model route into the web profile
#      exactly once (later edits through the UI persist untouched).
#   3. Start `dsh web` behind the deployment patch, mirror its output to
#      $DSH_HOME/logs, and capture the private first-visit URL with `?token=`.
#
# The process runs under tini (PID 1), which reaps orphans and forwards
# SIGTERM/SIGINT; this script forwards the signal to dsh and exits with its
# status so Docker restarts the container cleanly.

set -u

DSH_HOME="${DSH_HOME:-/data/dsh-home}"
DSH_WORKSPACE_DIR="${DSH_WORKSPACE_DIR:-/data/workspace}"
PORT="${PORT:-3080}"
DSH_PUBLIC_URL="${DSH_PUBLIC_URL:-}"
DEPLOY_PATCH="/opt/dsh-deploy/cordis.deploy.yml"
PROFILE_SEED="/opt/dsh-deploy/profile.seed.patch.yml"
SEED_MARKER="$DSH_HOME/.dsh-coolify-seeded"

log() { printf '[dsh] %s\n' "$*" >&2; }

mkdir -p \
  "$DSH_HOME" \
  "$DSH_HOME/logs" \
  "$DSH_HOME/sessions" \
  "$DSH_HOME/storages" \
  "$DSH_HOME/.ssh" \
  "$DSH_WORKSPACE_DIR"
chmod 700 "$DSH_HOME/.ssh" 2>/dev/null || true

# Keep the agent's Git/SSH identity on the volume: ssh keys, known_hosts and
# gitconfig survive container replacement because $HOME stays the image's
# /root and both paths are symlinked into $DSH_HOME.
if [ ! -e /root/.ssh ]; then ln -s "$DSH_HOME/.ssh" /root/.ssh; fi
if [ ! -e "$DSH_HOME/gitconfig" ]; then touch "$DSH_HOME/gitconfig"; fi
if [ ! -e /root/.gitconfig ]; then ln -s "$DSH_HOME/gitconfig" /root/.gitconfig; fi

# ── Seed the model route exactly once ───────────────────────────────────────
# The profile patch is the file the Web UI's Models page edits, so seeding it
# (rather than a home-level or CLI overlay) keeps later UI changes effective.
if [ ! -e "$SEED_MARKER" ]; then
  log "first boot: initializing the web profile"
  # `--dump-config` creates the profile directory and its empty user patch
  # without binding a server. Failure here is non-fatal: the real start below
  # reports the error with full diagnostics.
  DSH_HOME="$DSH_HOME" dsh --profile web --dump-config >/dev/null 2>&1 || true

  profile_patch="$DSH_HOME/profiles/web/cordis.patch.yml"
  if [ -f "$profile_patch" ] && ! grep -q 'dsh-gateway' "$profile_patch"; then
    stripped="$(sed -E 's/#.*$//' "$profile_patch" 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$stripped" ] || [ "$stripped" = '[]' ] || [ "$stripped" = '---' ]; then
      cp "$PROFILE_SEED" "$profile_patch"
    else
      printf '\n' >> "$profile_patch"
      cat "$PROFILE_SEED" >> "$profile_patch"
    fi
    log "seeded the env-driven model route (dsh-gateway) into the web profile"
  fi
  touch "$SEED_MARKER"
fi

cd "$DSH_WORKSPACE_DIR"

boot_log="$DSH_HOME/logs/boot-$(date -u +%Y%m%dT%H%M%SZ).log"
log "starting dsh web (home=$DSH_HOME workspace=$DSH_WORKSPACE_DIR port=$PORT)"

# Mirror stdout/stderr to the container log and a per-boot file so the
# `?token=` first-visit URL the server prints can be recovered later.
dsh --profile web --patch "$DEPLOY_PATCH" --no-open \
  > >(tee -a "$boot_log" >&2) 2>&1 &
dsh_pid=$!

# Recover the private first-visit URL from the boot log and publish it to a
# root-only file with the public authority substituted when DSH_PUBLIC_URL is
# set. The token is a bearer credential: never log the value itself.
login_file="$DSH_HOME/last-login-url.txt"
(
  for _ in $(seq 1 300); do
    if [ -s "$boot_log" ]; then
      token="$(grep -oE '\?token=[A-Za-z0-9_-]+' "$boot_log" | head -n1 | cut -d= -f2)"
      if [ -n "$token" ]; then
        if [ -n "$DSH_PUBLIC_URL" ]; then
          printf '%s/?token=%s\n' "${DSH_PUBLIC_URL%/}" "$token" > "$login_file"
        else
          origin="$(grep -oE 'https?://[^/]+/+\?token=' "$boot_log" | head -n1 | sed -E 's#(\?token=)?/?$##')"
          printf '%s/?token=%s\n' "${origin:-http://127.0.0.1:$PORT}" "$token" > "$login_file"
        fi
        chmod 600 "$login_file" 2>/dev/null || true
        log "first-visit URL ready: $login_file (open it once per browser)"
        log "current browsers stay signed in for DSH_COOKIE_MAX_AGE_DAYS; the file is rewritten every boot"
        exit 0
      fi
    fi
    kill -0 "$dsh_pid" 2>/dev/null || exit 0
    sleep 1
  done
) &
watcher_pid=$!

shutdown() {
  trap - TERM INT
  kill -TERM "$dsh_pid" 2>/dev/null || true
  wait "$dsh_pid" 2>/dev/null || true
  kill "$watcher_pid" 2>/dev/null || true
  exit 0
}
trap shutdown TERM INT

wait "$dsh_pid"
status=$?
kill "$watcher_pid" 2>/dev/null || true
wait "$watcher_pid" 2>/dev/null || true
exit "$status"

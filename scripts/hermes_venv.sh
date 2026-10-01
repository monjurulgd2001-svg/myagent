#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Hermes interpreter resolver (fix: "Hermes install is broken")
#
# WHY THIS FILE EXISTS
# Older Hermes installs kept their Python environment at a fixed path:
#     $HERMES_HOME/hermes-agent/venv/bin/python
# The current installer no longer does that. install.sh now only bootstraps a
# tool-Python and hands everything to PM ("PM alone creates dependency
# environments"), which puts the real application environment under:
#     $HERMES_HOME/installs/<hash>/environments/<hash>/{bin/python,workspace}
#
# So every hard-coded ".../hermes-agent/venv/bin/python" test in the workflow
# was ALWAYS false, even on a perfectly good install. That silently caused:
#   * the cache "skip install" branch to never trigger (full reinstall each run)
#   * the sanity check to declare "launcher broken" and reinstall a 2nd time
#   * the run to die with "::error::Hermes install is broken ..." / exit 1
#   * the edge-tts and python-telegram-bot repair blocks to be skipped, which
#     is what produced "Any cannot be instantiated" / NoAudioReceived later.
#
# Source this file and call resolve_hermes_py. It supports BOTH layouts, so it
# keeps working on old caches and on future installer versions.
# ──────────────────────────────────────────────────────────────────────────────

: "${HERMES_HOME:=$HOME/.hermes}"

# Print the path of the Python interpreter that runs the Hermes application
# (the one that has the agent's dependencies installed). Returns 1 if none.
resolve_hermes_py() {
  local cand envdir legacy_first="" with_workspace="" with_deps="" newest=""

  # 1. Legacy layout wins when present (an old cache / pinned older release).
  for cand in "$HERMES_HOME/hermes-agent/venv/bin/python" \
              "$HERMES_HOME/hermes-agent/.venv/bin/python"; do
    if [ -x "$cand" ]; then legacy_first="$cand"; break; fi
  done
  if [ -n "$legacy_first" ]; then printf '%s\n' "$legacy_first"; return 0; fi

  # 2. New PM layout. There can be several environments (PM's own tiny
  #    bootstrap env, agent-browser, the app env), so prefer the one that
  #    actually owns the app: it has a "workspace" next to it, or real
  #    application dependencies inside its site-packages.
  while IFS= read -r cand; do
    [ -x "$cand" ] || continue
    envdir="${cand%/bin/python}"
    [ -n "$newest" ] || newest="$cand"
    if [ -z "$with_workspace" ] && [ -e "$envdir/workspace" ]; then
      with_workspace="$cand"
    fi
    if [ -z "$with_deps" ] && \
       compgen -G "$envdir/lib/python*/site-packages/openai" >/dev/null 2>&1; then
      with_deps="$cand"
    fi
  done < <(ls -1dt "$HERMES_HOME"/installs/*/environments/*/bin/python 2>/dev/null || true)

  for cand in "$with_workspace" "$with_deps" "$newest"; do
    if [ -n "$cand" ]; then printf '%s\n' "$cand"; return 0; fi
  done
  return 1
}

# Export HERMES_VENV_PY (and persist it to $GITHUB_ENV for later steps).
export_hermes_py() {
  local py
  py="$(resolve_hermes_py || true)"
  if [ -n "$py" ]; then
    export HERMES_VENV_PY="$py"
    if [ -n "${GITHUB_ENV:-}" ]; then
      echo "HERMES_VENV_PY=$py" >> "$GITHUB_ENV"
    fi
    echo "Hermes app interpreter: $py"
    return 0
  fi
  echo "::warning::could not locate the Hermes application interpreter (checked hermes-agent/venv and $HERMES_HOME/installs/*/environments/*)"
  return 1
}

# Install/upgrade packages into the Hermes environment.
# uv-built environments ship WITHOUT pip, so try: pip -> uv pip -> ensurepip
# -> get-pip.py, exactly like the old inline helper did.
hermes_py_install() {
  local py="${HERMES_VENV_PY:-}" uv_bin=""
  [ -n "$py" ] || py="$(resolve_hermes_py || true)"
  [ -n "$py" ] && [ -x "$py" ] || return 1

  if "$py" -m pip --version >/dev/null 2>&1; then
    "$py" -m pip install -q -U "$@" && return 0
  fi
  uv_bin="$(command -v uv 2>/dev/null || true)"
  [ -z "$uv_bin" ] && [ -x "$HOME/.local/bin/uv" ] && uv_bin="$HOME/.local/bin/uv"
  [ -z "$uv_bin" ] && [ -x "$HOME/.local/share/uv/uv" ] && uv_bin="$HOME/.local/share/uv/uv"
  if [ -n "$uv_bin" ]; then
    "$uv_bin" pip install --python "$py" -q -U "$@" && return 0
  fi
  "$py" -m ensurepip --upgrade >/dev/null 2>&1 || true
  if ! "$py" -m pip --version >/dev/null 2>&1; then
    curl -fsSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py 2>/dev/null \
      && "$py" /tmp/get-pip.py --quiet || true
  fi
  "$py" -m pip install -q -U "$@"
}

:

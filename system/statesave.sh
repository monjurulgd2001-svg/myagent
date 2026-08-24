#!/bin/bash
mkdir -p "$HERMES_HOME/xdg-mirror/config" "$HERMES_HOME/xdg-mirror/share" "$HERMES_HOME/xdg-mirror/state" "$HERMES_HOME/agent-state"
for d in "$HOME/.config"/hermes* "$HOME/.config"/nous*; do [ -e "$d" ] && rsync -a --delete "$d" "$HERMES_HOME/xdg-mirror/config/" || true; done
for d in "$HOME/.local/share"/hermes* "$HOME/.local/share"/nous*; do [ -e "$d" ] && rsync -a --delete "$d" "$HERMES_HOME/xdg-mirror/share/" || true; done
for d in "$HOME/.local/state"/hermes* "$HOME/.local/state"/nous*; do [ -e "$d" ] && rsync -a --delete "$d" "$HERMES_HOME/xdg-mirror/state/" || true; done
# FULL agent tree - every file, any name, any depth (no whitelists)
if [ -d "$HERMES_HOME/hermes-agent" ]; then
  rsync -a --delete \
    --exclude='venv' --exclude='.venv' --exclude='.git' \
    --exclude='__pycache__' --exclude='*.pyc' --exclude='node_modules' \
    --exclude='.cache' --exclude='*.log' \
    "$HERMES_HOME/hermes-agent/" "$HERMES_HOME/agent-state/" || true
fi
SNAP=/tmp/statesnap
mkdir -p "$SNAP"
rsync -a --delete \
  --exclude='.env' --exclude='.git' --exclude='*.log' \
  --exclude='hermes-agent' \
  --exclude='browser-profile/cache2' --exclude='browser-profile/startupCache' \
  --exclude='browser-profile/shader-cache' \
  --exclude='chrome-profile/Default/Cache' --exclude='chrome-profile/Default/Code Cache' \
  --exclude='chrome-profile/Default/GPUCache' --exclude='chrome-profile/ShaderCache' \
  --exclude='chrome-profile/GraphiteDawnCache' \
  --exclude='state.db' --exclude='state.db-wal' --exclude='state.db-shm' \
  "$HERMES_HOME/" "$SNAP/" || true
# WAL-safe chats/sessions snapshot (a plain cp loses recent writes)
if [ -f "$HERMES_HOME/state.db" ]; then
  python3 - "$HERMES_HOME/state.db" "$SNAP/state.db" <<'PYDB' || cp -a "$HERMES_HOME/state.db" "$SNAP/" 2>/dev/null || true
import sqlite3, sys
src = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True, timeout=60)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
dst.close(); src.close()
print("state.db snapshot OK")
PYDB
fi
cd "$SNAP" || exit 0
find . -path ./.git -prune -o -type f -size +90M -print | while read -r f; do
  split -b 90M -d -a 3 "$f" "$f.gh-chunk."
  rm -f "$f"
done
printf '.env\n*.log\n' > .gitignore
{
  echo "# Hermes unified state - saved $(date -u +%FT%TZ)"
  echo "- agent files: $(find agent-state -type f 2>/dev/null | wc -l)"
  echo "- skills: $(find . -path ./.git -prune -o -name 'SKILL.md' -print 2>/dev/null | wc -l)"
  echo "- memory files: $(find memory memories -type f 2>/dev/null | wc -l)"
  echo "- work files: $(find work -type f 2>/dev/null | wc -l)"
  echo "- chats db: $(du -h state.db 2>/dev/null | cut -f1)"
  echo "- total: $(du -sh --exclude=.git . 2>/dev/null | cut -f1)"
} > MANIFEST.md
if [ ! -d .git ]; then
  git init -q -b state
  git config user.email "bot@hermes" && git config user.name "hermes-bot"
fi
git add -A
git commit -q -m "state $(date -u +%FT%TZ)" || true
pushed=""
for try in 1 2; do
  if timeout 300 git push -f "https://x-access-token:${DATA_REPO_TOKEN}@github.com/${DATA_REPO}.git" state >/tmp/statepush.log 2>&1; then pushed=1; break; fi
  sleep 5
done
if [ -n "$pushed" ]; then
  echo "state pushed OK $(date -u +%FT%TZ) - $(grep total MANIFEST.md || true)"
else
  echo "::warning::STATE PUSH FAILED twice - retrying next cycle"
  tail -3 /tmp/statepush.log || true
fi

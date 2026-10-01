#!/bin/bash
INBOX="$HERMES_HOME/work/inbox"
SKILLS="$HERMES_HOME/hermes-agent/skills"
MEM="$HERMES_HOME/memory/MEMORY.md"
mkdir -p "$INBOX" "$SKILLS" "$HERMES_HOME/memory"
STAMP=/tmp/sweep.stamp
touch "$STAMP"
EXTS='json|yaml|yml|md|txt|py|sh|js|ts|pdf|csv|html|toml|ini|cfg|svg|jpg|jpeg|png|gif|cmd|bat|zip|mp3|mp4|wav|docx|xlsx|pptx'
while true; do
  sleep 45
  NEW=$(mktemp)
  # Hermes drops Telegram/Slack uploads into EPHEMERAL cache dirs
  # under ~/.hermes (known upstream limitation) - sweep those too.
  for root in "$HOME/Downloads" "$HOME/Documents" "$HOME/Desktop" \
              "$HOME/.cache"/hermes* "$HOME/.cache"/nous* \
              "$HERMES_HOME/cache" "$HERMES_HOME/workspace" \
              "$HERMES_HOME/uploads" "$HERMES_HOME/media" \
              "$HERMES_HOME/hermes-agent/workspace" /tmp /var/tmp; do
    [ -d "$root" ] || continue
    find "$root" -maxdepth 3 -type f -newer "$STAMP" -size +0c 2>/dev/null \
      | grep -Ei "\.($EXTS)$" >> "$NEW" || true
  done
  touch "$STAMP"
  sort -u "$NEW" | while IFS= read -r f; do
    case "$f" in
      "$HERMES_HOME"/work/*|"$HERMES_HOME"/agent-state/*|"$HERMES_HOME"/xdg-mirror/*|"$HERMES_HOME"/memory/*|"$HERMES_HOME"/memories/*|/tmp/hot/*|/tmp/backup/*|/tmp/final/*|/tmp/statesnap/*|/tmp/data*|/tmp/hermes-keep/*|/tmp/camofox-browser/*|/tmp/sweep*|/tmp/keychk*|/tmp/get-pip.py|/tmp/hotsave.sh|/tmp/statesave.sh|/tmp/sync.sh|/tmp/watchdog.sh|/tmp/save.env) continue;;
    esac
    base=$(basename "$f")
    low=$(echo "$base" | tr 'A-Z' 'a-z')
    # ── skill files install themselves ──
    if [ "$low" = "skill.md" ] || [ "${low%.skill.md}" != "$low" ]; then
      sname=$(basename "$(dirname "$f")")
      case "$sname" in
        tmp|Downloads|Documents|Desktop|uploads|inbox) sname="${low%.skill.md}"; sname="${sname%.md}";;
      esac
      sname=$(echo "$sname" | tr ' ' '-' | tr -cd 'A-Za-z0-9._-')
      { [ -n "$sname" ] && [ "$sname" != "skill" ]; } || sname="skill-$(date +%s)"
      mkdir -p "$SKILLS/$sname"
      cp -f "$f" "$SKILLS/$sname/SKILL.md" 2>/dev/null || continue
      echo "- $(date '+%F %T') auto-installed skill '$sname' (from $f)" >> "$MEM"
      continue
    fi
    # ── everything else goes to the persisted inbox ──
    if [ ! -e "$INBOX/$base" ]; then
      cp -f "$f" "$INBOX/$base" 2>/dev/null || continue
      echo "- $(date '+%F %T') auto-saved incoming file: ~/.hermes/work/inbox/$base (from $f)" >> "$MEM"
    else
      cmp -s "$f" "$INBOX/$base" || cp -f "$f" "$INBOX/$base" 2>/dev/null || true
    fi
  done
  rm -f "$NEW"
done

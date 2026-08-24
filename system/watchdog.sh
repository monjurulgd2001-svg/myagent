#!/bin/bash
fails=0
while true; do
  sleep 60
  if curl -fs -m 15 http://localhost:4000/v1/models >/dev/null 2>&1; then
    fails=0
    continue
  fi
  fails=$((fails+1))
  echo "$(date) pool-router health check failed ($fails/3)"
  if ! pgrep -f pool-router.py >/dev/null 2>&1 || [ "$fails" -ge 3 ]; then
    echo "$(date) pool-router down/stuck - restarting"
    pkill -f pool-router.py 2>/dev/null || true
    sleep 1
    set -a; . /tmp/router.env 2>/dev/null || true; set +a
    setsid nohup python3 /tmp/pool-router.py >> /tmp/pool-router.log 2>&1 &
    fails=0
  fi
done

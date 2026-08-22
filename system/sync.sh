#!/bin/bash
# last-gasp save if this loop is signalled
trap '/tmp/statesave.sh; exit 0' TERM INT HUP
while true; do
  sleep 300 & wait $!
  /tmp/statesave.sh || true
done

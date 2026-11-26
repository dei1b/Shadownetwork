#!/usr/bin/env bash
set -euo pipefail

log_file="$(mktemp)"
trap 'rm -f "$log_file"' EXIT

for attempt in 1 2 3; do
  set +e
  "$@" 2>&1 | tee "$log_file"
  result=${PIPESTATUS[0]}
  set -e
  if (( result == 0 )); then
    exit 0
  fi
  if (( attempt == 3 )) || ! grep -Eq \
    'Received status code (429|502|503|504)|Gradle threw an error while downloading artifacts from the network' "$log_file"; then
    exit "$result"
  fi
  delay=$((attempt * 30))
  echo "::warning::Dependency download failed; retrying build in ${delay}s (attempt $((attempt + 1))/3)."
  sleep "$delay"
done

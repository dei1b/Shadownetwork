#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"
export PATH="$scratch/bin:$PATH"
cat > "$scratch/bin/sleep" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$CASE_DIR/delays"
SH
cat > "$scratch/bin/fake-build" <<'SH'
#!/usr/bin/env bash
[[ "$1" == 'argument with spaces' ]] || exit 99
count=$(cat "$CASE_DIR/count" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$CASE_DIR/count"
case "$MODE" in
  success) exit 0 ;;
  compiler) echo 'Java compilation failed'; exit 17 ;;
  recover) (( count > 1 )) && exit 0 ;;
esac
echo 'Received status code 429 from server: Too Many Requests'
exit 42
SH
chmod +x "$scratch/bin/"*
for mode in success recover compiler exhausted; do
  export MODE="$mode" CASE_DIR="$scratch/$mode"
  mkdir -p "$CASE_DIR"
  set +e
  bash "$repo/tools/ci/retry_gradle_downloads.sh" fake-build 'argument with spaces' > "$CASE_DIR/output" 2>&1
  result=$?
  set -e
  case "$mode" in
    success) [[ "$result" == 0 && "$(cat "$CASE_DIR/count")" == 1 && ! -f "$CASE_DIR/delays" ]] ;;
    recover) [[ "$result" == 0 && "$(cat "$CASE_DIR/count")" == 2 && "$(cat "$CASE_DIR/delays")" == 30 ]] ;;
    compiler) [[ "$result" == 17 && "$(cat "$CASE_DIR/count")" == 1 && ! -f "$CASE_DIR/delays" ]] ;;
    exhausted) [[ "$result" == 42 && "$(cat "$CASE_DIR/count")" == 3 && "$(tr '\n' ',' < "$CASE_DIR/delays")" == '30,60,' ]] ;;
  esac
  echo "PASS: $mode"
done

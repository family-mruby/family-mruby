#!/bin/bash
# Launch the Family mruby Linux simulation stack and capture a screenshot,
# so an agent (or CI) can verify the screen without a GUI.
#
# Usage: tools/dev_run_check.sh [--gui] [--keep] [output.png]
#   --gui   use the normal X11 SDL window instead of the headless override
#   --keep  leave the stack running after the screenshot (default: down)
#   output  screenshot path (default /tmp/fmrb_screen.png)
#
# If the stack is already running (fmruby_core container up), it is reused
# as-is: no recreate, no down. This keeps the script safe to run while a
# developer has `docker compose up` open in another terminal.
set -eu
cd "$(dirname "$0")/.."

GUI=0
KEEP=0
OUT=/tmp/fmrb_screen.png
for a in "$@"; do
  case "$a" in
    --gui) GUI=1 ;;
    --keep) KEEP=1 ;;
    *) OUT="$a" ;;
  esac
done

BOOT_MARKER="main_loop started"
BOOT_TIMEOUT="${FMRB_BOOT_TIMEOUT:-60}"

already_running=0
if [ "$(docker inspect -f '{{.State.Running}}' fmruby_core 2>/dev/null)" = "true" ]; then
  already_running=1
  echo "fmruby_core is already running; reusing the existing stack"
else
  if [ "$GUI" = "1" ]; then
    docker compose up -d
  else
    docker compose -f docker-compose.yml -f docker-compose.headless.yml up -d
  fi
fi

# Wait for the kernel main loop (or timeout) before capturing.
echo "waiting for boot marker '\"$BOOT_MARKER\"' (timeout ${BOOT_TIMEOUT}s)..."
end=$((SECONDS + BOOT_TIMEOUT))
while [ $SECONDS -lt $end ]; do
  if docker logs fmruby_core 2>&1 | grep -q "$BOOT_MARKER"; then
    break
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' fmruby_core 2>/dev/null)" != "true" ] && [ $already_running = 0 ]; then
    echo "fmruby_core exited during boot; last log lines:" >&2
    docker logs --tail 30 fmruby_core >&2 || true
    [ "$KEEP" = "1" ] || docker compose down
    exit 1
  fi
  sleep 1
done

# Give the desktop a moment to draw its first frame after the kernel is up.
sleep 3

python3 tools/fmrb_screenshot.py --wait 10 "$OUT"
rc=$?

if [ "$KEEP" != "1" ] && [ $already_running = 0 ]; then
  docker compose down
fi
exit $rc

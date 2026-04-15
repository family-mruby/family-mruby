#!/bin/bash
# Start Family mruby processes in correct order:
#   1. sdl2-display (waits for SHM connection)
#   2. fmruby-graphics-audio.elf (creates SHM, connects to sdl2-display)
#   3. fmruby-core.elf (connects to graphics-audio)
set -e

FMRUBY_DIR=/opt/fmruby
BIN_DIR=${FMRUBY_DIR}/bin
SOCKET_DIR=/var/run/fmrb
LOG_DIR=/tmp/fmruby-logs

mkdir -p "${LOG_DIR}"
mkdir -p "${SOCKET_DIR}"

# Clean up stale sockets
rm -f "${SOCKET_DIR}/fmrb_socket" "${SOCKET_DIR}/fmrb_input_socket"

# Wait for VNC display to be available
echo "[fmruby] Waiting for VNC display :1..."
for i in $(seq 1 30); do
    if [ -e /tmp/.X11-unix/X1 ]; then
        echo "[fmruby] VNC display :1 ready."
        break
    fi
    sleep 1
done
if [ ! -e /tmp/.X11-unix/X1 ]; then
    echo "[fmruby] ERROR: VNC display :1 not available."
    exit 1
fi

# Each ELF uses relative path "flash/" - run from its own directory
GA_DIR=${FMRUBY_DIR}/ga
CORE_DIR=${FMRUBY_DIR}/core

echo "[fmruby] Starting sdl2-display..."
DISPLAY=:1 ${BIN_DIR}/sdl2-display > "${LOG_DIR}/sdl2-display.log" 2>&1 &
SDL2_PID=$!
sleep 1

echo "[fmruby] Starting fmruby-graphics-audio (cwd=${GA_DIR})..."
cd ${GA_DIR}
${BIN_DIR}/fmruby-graphics-audio.elf > "${LOG_DIR}/graphics-audio.log" 2>&1 &
GA_PID=$!

# Wait for sockets to appear
echo "[fmruby] Waiting for IPC sockets..."
for i in $(seq 1 30); do
    if [ -S "${SOCKET_DIR}/fmrb_socket" ] && [ -S "${SOCKET_DIR}/fmrb_input_socket" ]; then
        echo "[fmruby] IPC sockets ready."
        break
    fi
    sleep 1
done

if [ ! -S "${SOCKET_DIR}/fmrb_socket" ]; then
    echo "[fmruby] ERROR: IPC sockets not created. Check logs in ${LOG_DIR}/"
    exit 1
fi

echo "[fmruby] Starting fmruby-core (cwd=${CORE_DIR})..."
cd ${CORE_DIR}
${BIN_DIR}/fmruby-core.elf > "${LOG_DIR}/core.log" 2>&1 &
CORE_PID=$!

echo "[fmruby] All processes started (sdl2=$SDL2_PID, ga=$GA_PID, core=$CORE_PID)"

# Handle shutdown
cleanup() {
    echo "[fmruby] Shutting down..."
    kill $CORE_PID $GA_PID $SDL2_PID 2>/dev/null || true
    wait
}
trap cleanup SIGTERM SIGINT

# Wait for any child to exit
wait -n
echo "[fmruby] A process exited. Shutting down all..."
cleanup

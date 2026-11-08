#!/bin/zsh
#
# Keep byte for byte identical to the copy in the other repo -- swift-libssh and
# sshadow share one server.

set -e

PID_FILE="/tmp/ssh-test-server-$(id -un)/sshd.pid"

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    kill $PID 2>/dev/null || true
    rm -f "$PID_FILE"
    echo "✅ SSH Server with PID $PID stopped"
fi

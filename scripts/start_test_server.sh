#!/bin/zsh
#
# Keep byte for byte identical to the copy in the other repo -- swift-libssh and
# sshadow share one server.

set -e

SERVER_DIR="${0:a:h}/test_server"
USER_NAME=$(id -un)
RUNTIME_DIR="/tmp/ssh-test-server-$USER_NAME"
HOST_KEY="$RUNTIME_DIR/host_key_ed25519"
PID_FILE="$RUNTIME_DIR/sshd.pid"
LOG_FILE="$RUNTIME_DIR/sshd.log"
PORT=$(awk '/^Port /{print $2}' "$SERVER_DIR/sshd_config")

mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "✅ Reusing SSH Server on port $PORT with PID $(cat "$PID_FILE")"
    exit 0
fi

if [[ ! -f "$HOST_KEY" ]]; then
    ssh-keygen -q -t ed25519 -N '' -C 'test server' -f "$HOST_KEY"
fi

rm -f "$LOG_FILE" "$PID_FILE"

/usr/sbin/sshd \
    -f "$SERVER_DIR/sshd_config" \
    -E "$LOG_FILE" \
    -h "$HOST_KEY" \
    -o "PidFile $PID_FILE" \
    -o "AuthorizedKeysFile $SERVER_DIR/authorized_keys"

retries=50
while [[ ! -f "$PID_FILE" ]]; do
    if (( retries-- == 0 )); then
        echo "❌ Failed to start SSH server: PID file not found after waiting."
        cat "$LOG_FILE"
        exit 1
    fi
    sleep 0.1
done

echo "✅ SSH Server started on port $PORT as $USER_NAME with PID $(cat "$PID_FILE")"

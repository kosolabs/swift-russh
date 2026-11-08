default: test

start-test-server:
    ./scripts/start_test_server.sh

stop-test-server:
    ./scripts/stop_test_server.sh

test: start-test-server
    swift test

stress *args="--workers 8 --iterations 25": start-test-server
    swift run -c release SwiftSSH stress \
        -i Tests/Data/id_ed25519 -p 2248 -l "$(whoami)" localhost {{args}}

stress-tree *args="--workers 8 --rounds 3": start-test-server
    swift run -c release SwiftSSH stress-tree \
        -i Tests/Data/id_ed25519 -p 2248 -l "$(whoami)" localhost {{args}}

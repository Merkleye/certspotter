# Subprocess-level tests for supervise.sh's top-level boot sequence and
# refresh loop -- the two blocks of code that live outside any function
# (see the SUPERVISE_SOURCE_ONLY note in supervise.sh) because their
# `continue`s target the refresh `while` directly and do not survive being
# moved into a callable function. tests/supervise_unit.bats covers every
# other function by sourcing the script; these run the real script as a
# background process against a fake certspotter and a scripted fake curl to
# exercise that remaining code the only way its own control flow allows.

load helpers.bash

setup() {
    mock_curl_setup
    fake_certspotter_setup
    export FAKE_CERTSPOTTER_MODE=run
    export MERKLEYE_WATCHLIST_URL="http://backend/internal/v1/watchlist"
    export CERTSPOTTER_STATE_DIR="$BATS_TEST_TMPDIR/state"
    mkdir -p "$CERTSPOTTER_STATE_DIR"
    export MERKLEYE_HOOK_SECRET="testsecret"
    export MERKLEYE_WATCHLIST_RETRY_INTERVAL=1
    export MERKLEYE_WATCHLIST_MIN_RESTART_INTERVAL=0
    export MERKLEYE_WATCHLIST_SETTLE_SECONDS=1
    export MERKLEYE_WATCHLIST_WAIT=1s
    SUPERVISE_PID=""
}

teardown() {
    if [ -n "$SUPERVISE_PID" ] && kill -0 "$SUPERVISE_PID" 2>/dev/null; then
        kill -KILL "$SUPERVISE_PID" 2>/dev/null || true
        wait "$SUPERVISE_PID" 2>/dev/null || true
    fi
    pkill -KILL -f "$BATS_TEST_DIRNAME/bin/certspotter" 2>/dev/null || true
}

start_supervise() {
    bash "$BATS_TEST_DIRNAME/../supervise.sh" >"$BATS_TEST_TMPDIR/supervise.log" 2>&1 &
    SUPERVISE_PID=$!
}

# digest_of ENTRY... -- the sha256 verify_digest will compute for a
# watchlist file made of these entries, one per line. Real digests, not
# arbitrary strings: verify_digest hashes the actual paged file and rejects
# anything that doesn't match, same as the real backend's watchlist view.
digest_of() {
    printf '%s\n' "$@" | sha256sum | cut -d' ' -f1
}

@test "supervise.sh fetches the watchlist on a cold boot and starts certspotter" {
    digest="$(digest_of a.example)"
    queue_curl_response 0 "{\"digest\":\"$digest\",\"total\":1}"
    queue_curl_response 0 '{"entries":["a.example"],"next_cursor":""}'

    start_supervise
    wait_until test -s "$CERTSPOTTER_STATE_DIR/watchlist.txt"
    [ "$(cat "$CERTSPOTTER_STATE_DIR/watchlist.digest")" = "$digest" ]
    grep -q 'a.example' "$CERTSPOTTER_STATE_DIR/watchlist.txt"
    wait_until test -s "$FAKE_CERTSPOTTER_LOG"
    grep -q -- '-watchlist' "$FAKE_CERTSPOTTER_LOG"

    kill -TERM "$SUPERVISE_PID"
    if wait "$SUPERVISE_PID"; then status=0; else status=$?; fi
    [ "$status" -eq 0 ]
    grep -q "shutting down" "$BATS_TEST_TMPDIR/supervise.log"
}

@test "supervise.sh retries the initial fetch after a backend failure" {
    digest="$(digest_of a.example)"
    queue_curl_response 22 ''
    queue_curl_response 0 "{\"digest\":\"$digest\",\"total\":1}"
    queue_curl_response 0 '{"entries":["a.example"],"next_cursor":""}'

    start_supervise
    wait_until test -s "$CERTSPOTTER_STATE_DIR/watchlist.txt"
    [ "$(cat "$CERTSPOTTER_STATE_DIR/watchlist.digest")" = "$digest" ]
    grep -q "backend unreachable; retrying" "$BATS_TEST_TMPDIR/supervise.log"

    kill -TERM "$SUPERVISE_PID"
    wait "$SUPERVISE_PID" 2>/dev/null || true
}

@test "supervise.sh restarts certspotter when the watchlist changes" {
    old_digest="$(digest_of a.example)"
    new_digest="$(digest_of a.example b.example)"
    printf 'a.example\n' >"$CERTSPOTTER_STATE_DIR/watchlist.txt"
    printf '%s\n' "$old_digest" >"$CERTSPOTTER_STATE_DIR/watchlist.digest"
    queue_curl_response 0 "{\"digest\":\"$new_digest\",\"total\":2}"
    queue_curl_response 0 '{"entries":["a.example","b.example"],"next_cursor":""}'

    start_supervise
    wait_until test -s "$FAKE_CERTSPOTTER_LOG"

    wait_until bash -c '[ "$(cat "$1")" = "$2" ]' -- "$CERTSPOTTER_STATE_DIR/watchlist.digest" "$new_digest"
    grep -q 'b.example' "$CERTSPOTTER_STATE_DIR/watchlist.txt"
    wait_until bash -c '[ "$(grep -c -- "-watchlist" "$1")" -ge 2 ]' -- "$FAKE_CERTSPOTTER_LOG"

    kill -TERM "$SUPERVISE_PID"
    wait "$SUPERVISE_PID" 2>/dev/null || true
}

@test "supervise.sh exits with certspotter's status when it dies unexpectedly" {
    digest="$(digest_of a.example)"
    printf 'a.example\n' >"$CERTSPOTTER_STATE_DIR/watchlist.txt"
    printf '%s\n' "$digest" >"$CERTSPOTTER_STATE_DIR/watchlist.digest"
    export FAKE_CERTSPOTTER_MODE=crash_after
    export FAKE_CERTSPOTTER_CRASH_DELAY=2
    export FAKE_CERTSPOTTER_EXIT=3

    start_supervise
    # The synchronization point here is the process actually exiting, not
    # some intermediate file state: block on `wait` rather than polling the
    # log file for a message beforehand.
    #
    # This only asserts the exit code, not the "certspotter exited
    # unexpectedly" log line the same code path also writes (grep for it
    # locally and it's there): under bashcov specifically, that line is
    # lost often enough to make the assertion flaky, while the propagated
    # exit code -- produced by the same, only `exit "$rc"` in the file --
    # is not, so it alone is what this test relies on.
    if wait "$SUPERVISE_PID"; then status=0; else status=$?; fi
    [ "$status" -eq 3 ]
}

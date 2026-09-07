bats_require_minimum_version 1.5.0

load helpers.bash

setup() {
    mock_curl_setup
    fake_certspotter_setup
    export SUPERVISE_SOURCE_ONLY=1
    export MERKLEYE_WATCHLIST_URL="http://backend/internal/v1/watchlist"
    export CERTSPOTTER_STATE_DIR="$BATS_TEST_TMPDIR/state"
    mkdir -p "$CERTSPOTTER_STATE_DIR"
    export MERKLEYE_HOOK_SECRET="testsecret"
    # shellcheck disable=SC1091
    . "$BATS_TEST_DIRNAME/../supervise.sh"
}

# --- sourcing / startup validation ---------------------------------------

@test "supervise.sh reads the shared secret from MERKLEYE_HOOK_SECRET_FILE" {
    unset MERKLEYE_HOOK_SECRET
    secret_file="$BATS_TEST_TMPDIR/secret"
    echo -n "file-secret" >"$secret_file"
    export MERKLEYE_HOOK_SECRET_FILE="$secret_file"
    # shellcheck disable=SC1091
    . "$BATS_TEST_DIRNAME/../supervise.sh"
    [ "$hook_secret" = "file-secret" ]
}

# The exact exit status a `${var:?msg}` failure produces when sourced from
# a `bash -c` one-liner isn't portable across bash versions (observed 127
# here), so these only assert that sourcing fails, not which code it fails
# with -- `run !` accepts any non-zero status without bats' unmatched-code
# warning.
@test "supervise.sh requires MERKLEYE_WATCHLIST_URL" {
    unset MERKLEYE_WATCHLIST_URL
    run ! bash -c '. "$1"' -- "$BATS_TEST_DIRNAME/../supervise.sh"
}

@test "supervise.sh requires a shared secret" {
    unset MERKLEYE_HOOK_SECRET
    run ! bash -c '. "$1"' -- "$BATS_TEST_DIRNAME/../supervise.sh"
}

# --- report_status -----------------------------------------------------

@test "report_status is a no-op when MERKLEYE_HOOK_URL is unset" {
    report_status synced "abc123" true
    [ "$(curl_call_count)" -eq 0 ]
}

@test "report_status posts outcome, digest, in_sync and summary" {
    MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    report_status synced "abc123" true "all good"
    [ "$(curl_call_count)" -eq 1 ]
    body="$(curl_call_body 1)"
    [ "$(echo "$body" | jq -r '.event')" = "watchlist_status" ]
    [ "$(echo "$body" | jq -r '.outcome')" = "synced" ]
    [ "$(echo "$body" | jq -r '.digest')" = "abc123" ]
    [ "$(echo "$body" | jq -r '.in_sync')" = "true" ]
    [ "$(echo "$body" | jq -r '.summary')" = "all good" ]
    [ "$(echo "$body" | jq -r '.entries')" = "0" ]
}

@test "report_status counts entries from the installed watchlist" {
    MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    printf 'a.example\nb.example\nc.example\n' >"$watchlist"
    report_status unchanged "abc123" true
    body="$(curl_call_body 1)"
    [ "$(echo "$body" | jq -r '.entries')" = "3" ]
}

@test "report_status logs a non-fatal warning when the POST fails" {
    MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    export MOCK_CURL_DEFAULT_EXIT=22
    run report_status fetch_failed "" false "backend unreachable"
    [ "$status" -eq 0 ]
    [[ "$output" == *"watchlist status POST failed (non-fatal)"* ]]
}

# --- certspotter_alive ---------------------------------------------------

@test "certspotter_alive is false when no pid is recorded" {
    cs_pid=""
    run certspotter_alive
    [ "$status" -ne 0 ]
}

@test "certspotter_alive is true for a running process" {
    sleep 5 &
    cs_pid=$!
    certspotter_alive
    kill "$cs_pid" 2>/dev/null || true
}

@test "certspotter_alive is false for a pid that does not exist" {
    cs_pid=999999
    run certspotter_alive
    [ "$status" -ne 0 ]
}

# --- curl_auth -----------------------------------------------------------

@test "curl_auth sends the shared secret header and forwards arguments" {
    curl_auth --max-time 5 "http://backend/internal/v1/watchlist/version"
    [ "$(curl_call_count)" -eq 1 ]
    call="$(nth_curl_call 1)"
    echo "$call" | grep -q "X-Merkleye-Hook-Secret: testsecret"
    echo "$call" | grep -q "http://backend/internal/v1/watchlist/version"
}

# --- verify_digest ---------------------------------------------------------

@test "verify_digest accepts a matching sha256" {
    file="$BATS_TEST_TMPDIR/list.txt"
    printf 'a.example\n' >"$file"
    digest="$(sha256sum "$file" | cut -d' ' -f1)"
    run verify_digest "$file" "$digest"
    [ "$status" -eq 0 ]
}

@test "verify_digest rejects a mismatched sha256" {
    file="$BATS_TEST_TMPDIR/list.txt"
    printf 'a.example\n' >"$file"
    run verify_digest "$file" "not-the-real-digest"
    [ "$status" -ne 0 ]
}

# --- fetch_watchlist -------------------------------------------------------

@test "fetch_watchlist writes a single page with no cursor" {
    queue_curl_response 0 '{"entries":["a.example","b.example"],"next_cursor":""}'
    out="$BATS_TEST_TMPDIR/out.txt"
    run fetch_watchlist "$out"
    [ "$status" -eq 0 ]
    [ "$(wc -l <"$out" | tr -d ' ')" -eq 2 ]
    grep -q 'a.example' "$out"
}

@test "fetch_watchlist follows a next_cursor across pages" {
    queue_curl_response 0 '{"entries":["a.example"],"next_cursor":"page2"}'
    queue_curl_response 0 '{"entries":["b.example"],"next_cursor":""}'
    out="$BATS_TEST_TMPDIR/out.txt"
    run fetch_watchlist "$out"
    [ "$status" -eq 0 ]
    [ "$(wc -l <"$out" | tr -d ' ')" -eq 2 ]
}

@test "fetch_watchlist accepts an empty page" {
    queue_curl_response 0 '{"entries":[],"next_cursor":""}'
    out="$BATS_TEST_TMPDIR/out.txt"
    run fetch_watchlist "$out"
    [ "$status" -eq 0 ]
    [ "$(wc -l <"$out" | tr -d ' ')" -eq 0 ]
}

@test "fetch_watchlist fails when curl_auth fails" {
    export MOCK_CURL_DEFAULT_EXIT=22
    out="$BATS_TEST_TMPDIR/out.txt"
    run fetch_watchlist "$out"
    [ "$status" -ne 0 ]
}

@test "fetch_watchlist fails on an unparseable page body" {
    queue_curl_response 0 'not json'
    out="$BATS_TEST_TMPDIR/out.txt"
    run fetch_watchlist "$out"
    [ "$status" -ne 0 ]
    [[ "$output" == *"failed to parse watchlist page"* ]]
}

@test "fetch_watchlist gives up after max_pages" {
    max_pages=2
    queue_curl_response 0 '{"entries":["a.example"],"next_cursor":"page2"}'
    queue_curl_response 0 '{"entries":["b.example"],"next_cursor":"page3"}'
    out="$BATS_TEST_TMPDIR/out.txt"
    run fetch_watchlist "$out"
    [ "$status" -ne 0 ]
    [[ "$output" == *"pagination exceeded 2 pages"* ]]
}

# --- start_certspotter / stop_certspotter / restart_certspotter -----------

@test "start_certspotter launches certspotter and records its pid" {
    printf 'a.example\n' >"$watchlist"
    export FAKE_CERTSPOTTER_MODE=run
    start_certspotter
    [ -n "$cs_pid" ]
    kill -0 "$cs_pid"
    [ "$last_restart" -gt 0 ]
    kill -TERM "$cs_pid" 2>/dev/null || true
    wait "$cs_pid" 2>/dev/null || true
}

@test "stop_certspotter is a no-op when no pid is recorded" {
    cs_pid=""
    run stop_certspotter
    [ "$status" -eq 0 ]
}

@test "stop_certspotter terminates a running certspotter" {
    printf 'a.example\n' >"$watchlist"
    export FAKE_CERTSPOTTER_MODE=run
    start_certspotter
    stop_certspotter
    [ -z "$cs_pid" ]
}

@test "stop_certspotter force-kills a certspotter that ignores TERM" {
    mkdir -p "$BATS_TEST_TMPDIR/instant"
    cat >"$BATS_TEST_TMPDIR/instant/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$BATS_TEST_TMPDIR/instant/sleep"
    export PATH="$BATS_TEST_TMPDIR/instant:$PATH"

    printf 'a.example\n' >"$watchlist"
    export FAKE_CERTSPOTTER_MODE=ignore_term
    start_certspotter
    pid_before="$cs_pid"
    # A forced SIGKILL makes `wait "$cs_pid"` inside stop_certspotter report
    # a 137 exit status. supervise.sh itself only runs under `set -u` (not
    # -e), so that alone is harmless there -- but bats runs every @test body
    # under `set -e`, and sourcing the script into that body doesn't change
    # that. A *bare* call to stop_certspotter from here would abort this
    # test right at that `wait`, skipping `cs_pid=""` and everything after
    # it, purely as an artifact of bats' own harness. Calling it as an `if`
    # condition exempts that from -e (bash doesn't apply -e to a command
    # whose status is being tested), letting this test observe the
    # function's own complete, real behavior.
    if stop_certspotter; then :; fi
    [ -z "$cs_pid" ]
    ! kill -0 "$pid_before" 2>/dev/null
}

# restart_certspotter is called directly rather than through bats' `run`:
# `run` forks a subshell, and cs_pid/last_restart are plain (non-exported)
# shell variables that a function shares with its caller only within the
# same process -- a subshell's writes to them never make it back, leaving
# the test holding a stale, already-signalled pid. Direct calls with output
# redirected to a log file keep everything in one process.

@test "restart_certspotter swaps in the new watchlist and stays up" {
    printf 'a.example\n' >"$watchlist"
    export FAKE_CERTSPOTTER_MODE=run
    settle_seconds=1
    min_restart_interval=0
    last_restart=0
    start_certspotter
    printf 'a.example\nb.example\n' >"$watchlist"
    log="$BATS_TEST_TMPDIR/restart.log"
    restart_certspotter >"$log" 2>&1
    status=$?
    [ "$status" -eq 0 ]
    kill -TERM "$cs_pid" 2>/dev/null || true
    wait "$cs_pid" 2>/dev/null || true
}

@test "restart_certspotter coalesces restarts inside min_restart_interval" {
    printf 'a.example\n' >"$watchlist"
    export FAKE_CERTSPOTTER_MODE=run
    settle_seconds=1
    min_restart_interval=1
    last_restart="$(date +%s)"
    start_certspotter
    log="$BATS_TEST_TMPDIR/restart.log"
    restart_certspotter >"$log" 2>&1
    status=$?
    [ "$status" -eq 0 ]
    grep -q "coalescing restart" "$log"
    kill -TERM "$cs_pid" 2>/dev/null || true
    wait "$cs_pid" 2>/dev/null || true
}

@test "restart_certspotter rolls back when certspotter rejects the new watchlist" {
    printf 'a.example\n' >"$watchlist"
    cp "$watchlist" "$watchlist_prev"
    export FAKE_CERTSPOTTER_MODE=run
    settle_seconds=2
    min_restart_interval=0
    last_restart=0
    start_certspotter

    printf 'bad line\n' >"$watchlist"
    touch "$digest_file"
    export FAKE_CERTSPOTTER_MODE=crash
    export FAKE_CERTSPOTTER_EXIT=1
    log="$BATS_TEST_TMPDIR/restart.log"
    # restart_certspotter legitimately returns 1 here; see stop_certspotter's
    # test above for why a bare call isn't safe from within a bats test body
    # (which runs under bats' own `set -e`) when the test needs to see that
    # non-zero status rather than have bats abort the test on it.
    if restart_certspotter >"$log" 2>&1; then status=0; else status=$?; fi
    [ "$status" -ne 0 ]
    grep -q "rolling back to the previous watchlist" "$log"
    [ ! -f "$digest_file" ]
    kill -TERM "$cs_pid" 2>/dev/null || true
    wait "$cs_pid" 2>/dev/null || true
}

@test "restart_certspotter gives up when certspotter rejects the watchlist with nothing to roll back to" {
    printf 'bad line\n' >"$watchlist"
    rm -f "$watchlist_prev"
    export FAKE_CERTSPOTTER_MODE=crash
    export FAKE_CERTSPOTTER_EXIT=1
    settle_seconds=2
    min_restart_interval=0
    last_restart=0
    log="$BATS_TEST_TMPDIR/restart.log"
    if restart_certspotter >"$log" 2>&1; then status=0; else status=$?; fi
    [ "$status" -ne 0 ]
    grep -q "no previous watchlist to roll back to" "$log"
}

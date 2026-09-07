load helpers.bash

setup() {
    mock_curl_setup
    export MOCK_PGREP_EXIT=0
    export CERTSPOTTER_STATE_DIR="$BATS_TEST_TMPDIR/state"
    mkdir -p "$CERTSPOTTER_STATE_DIR"
    touch "$CERTSPOTTER_STATE_DIR/checkpoint.json"
}

run_healthcheck() {
    run bash "$BATS_TEST_DIRNAME/../healthcheck.sh"
}

@test "healthcheck.sh fails when CERTSPOTTER_STATE_DIR is unset" {
    unset CERTSPOTTER_STATE_DIR
    run_healthcheck
    [ "$status" -ne 0 ]
}

@test "healthcheck.sh fails when certspotter is not running" {
    export MOCK_PGREP_EXIT=1
    run_healthcheck
    [ "$status" -eq 1 ]
    [[ "$output" == *"certspotter process not running"* ]]
    [ "$(curl_call_count)" -eq 0 ]
}

@test "healthcheck.sh fails when no file has been touched recently" {
    touch -d '-1 hour' "$CERTSPOTTER_STATE_DIR/checkpoint.json"
    export MERKLEYE_HEALTHCHECK_STALE_MINUTES=10
    run_healthcheck
    [ "$status" -eq 1 ]
    [[ "$output" == *"no checkpoint activity"* ]]
}

@test "healthcheck.sh ignores watchlist files when checking staleness" {
    rm -f "$CERTSPOTTER_STATE_DIR/checkpoint.json"
    touch "$CERTSPOTTER_STATE_DIR/watchlist.txt"
    touch "$CERTSPOTTER_STATE_DIR/.watchlist.digest"
    run_healthcheck
    [ "$status" -eq 1 ]
}

@test "healthcheck.sh succeeds with a fresh checkpoint and no hook configured" {
    run_healthcheck
    [ "$status" -eq 0 ]
    [ "$(curl_call_count)" -eq 0 ]
}

@test "healthcheck.sh posts a heartbeat using MERKLEYE_HOOK_SECRET" {
    export MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    export MERKLEYE_HOOK_SECRET="testsecret"
    run_healthcheck
    [ "$status" -eq 0 ]
    [ "$(curl_call_count)" -ge 1 ]
    nth_curl_call 1 | grep -q "X-Merkleye-Hook-Secret: testsecret"
}

@test "healthcheck.sh posts a heartbeat using MERKLEYE_HOOK_SECRET_FILE" {
    export MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    secret_file="$BATS_TEST_TMPDIR/secret"
    echo -n "file-secret" >"$secret_file"
    export MERKLEYE_HOOK_SECRET_FILE="$secret_file"
    run_healthcheck
    [ "$status" -eq 0 ]
    nth_curl_call 1 | grep -q "X-Merkleye-Hook-Secret: file-secret"
}

@test "healthcheck.sh does not fail when the heartbeat POST fails" {
    export MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    export MERKLEYE_HOOK_SECRET="testsecret"
    export MOCK_CURL_DEFAULT_EXIT=22
    run_healthcheck
    [ "$status" -eq 0 ]
    [[ "$output" == *"heartbeat POST failed (non-fatal)"* ]]
}

@test "healthcheck.sh sends nothing further when logs_dir does not exist" {
    export MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    export MERKLEYE_HOOK_SECRET="testsecret"
    run_healthcheck
    [ "$status" -eq 0 ]
    [ "$(curl_call_count)" -eq 1 ]
}

@test "healthcheck.sh sends nothing further when logs_dir is empty" {
    export MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    export MERKLEYE_HOOK_SECRET="testsecret"
    mkdir -p "$CERTSPOTTER_STATE_DIR/logs"
    run_healthcheck
    [ "$status" -eq 0 ]
    [ "$(curl_call_count)" -eq 1 ]
}

@test "healthcheck.sh skips a log directory with an unreadable state.json" {
    export MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    export MERKLEYE_HOOK_SECRET="testsecret"
    log_dir="$CERTSPOTTER_STATE_DIR/logs/log1"
    mkdir -p "$log_dir"
    run_healthcheck
    [ "$status" -eq 0 ]
    [ "$(curl_call_count)" -eq 1 ]
}

@test "healthcheck.sh posts log_status with per-log checkpoint state" {
    export MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    export MERKLEYE_HOOK_SECRET="testsecret"
    log_dir="$CERTSPOTTER_STATE_DIR/logs/log1"
    mkdir -p "$log_dir"
    cat >"$log_dir/state.json" <<'JSON'
{"verified_position":{"size":100},"download_position":{"size":120},"verified_sth":{"timestamp":1700000000000}}
JSON

    run_healthcheck
    [ "$status" -eq 0 ]
    [ "$(curl_call_count)" -eq 2 ]
    body="$(curl_call_body 2)"
    [ "$(echo "$body" | jq -r '.event')" = "log_status" ]
    [ "$(echo "$body" | jq -r '.logs[0].log_id')" = "log1" ]
    [ "$(echo "$body" | jq -r '.logs[0].checkpoint_size')" = "100" ]
    [ "$(echo "$body" | jq -r '.logs[0].download_size')" = "120" ]
}

@test "healthcheck.sh falls back to last_success when verified_sth is absent" {
    export MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    export MERKLEYE_HOOK_SECRET="testsecret"
    log_dir="$CERTSPOTTER_STATE_DIR/logs/log1"
    mkdir -p "$log_dir"
    cat >"$log_dir/state.json" <<'JSON'
{"last_success":"2024-01-01T00:00:00Z"}
JSON

    run_healthcheck
    [ "$status" -eq 0 ]
    body="$(curl_call_body 2)"
    [ "$(echo "$body" | jq -r '.logs[0].checkpoint_at')" = "2024-01-01T00:00:00Z" ]
}

@test "healthcheck.sh includes the most recent per-log error" {
    export MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    export MERKLEYE_HOOK_SECRET="testsecret"
    log_dir="$CERTSPOTTER_STATE_DIR/logs/log1"
    errors_dir="$log_dir/errors"
    mkdir -p "$errors_dir"
    echo '{}' >"$log_dir/state.json"
    echo "2024-01-01T00:00:00Z connection refused" >"$errors_dir/2024-01-01"
    sleep 0.01
    echo "2024-01-02T00:00:00Z timeout" >"$errors_dir/2024-01-02"

    run_healthcheck
    [ "$status" -eq 0 ]
    body="$(curl_call_body 2)"
    [ "$(echo "$body" | jq -r '.logs[0].last_error_at')" = "2024-01-02T00:00:00Z" ]
    [ "$(echo "$body" | jq -r '.logs[0].last_error')" = "timeout" ]
}

@test "healthcheck.sh does not fail when the log_status POST fails" {
    export MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    export MERKLEYE_HOOK_SECRET="testsecret"
    export MOCK_CURL_DEFAULT_EXIT=22
    log_dir="$CERTSPOTTER_STATE_DIR/logs/log1"
    mkdir -p "$log_dir"
    echo '{}' >"$log_dir/state.json"

    run_healthcheck
    [ "$status" -eq 0 ]
    [[ "$output" == *"log_status POST failed (non-fatal)"* ]]
}

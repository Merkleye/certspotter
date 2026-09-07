load helpers.bash

setup() {
    mock_curl_setup
}

run_hook() {
    run bash "$BATS_TEST_DIRNAME/../hook.sh"
}

@test "hook.sh fails when MERKLEYE_HOOK_URL is unset" {
    run_hook
    [ "$status" -ne 0 ]
    [ "$(curl_call_count)" -eq 0 ]
}

@test "hook.sh fails when no secret is available" {
    export MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    run_hook
    [ "$status" -ne 0 ]
    [ "$(curl_call_count)" -eq 0 ]
}

@test "hook.sh reads the secret from MERKLEYE_HOOK_SECRET_FILE" {
    export MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    secret_file="$BATS_TEST_TMPDIR/secret"
    echo -n "file-secret" >"$secret_file"
    export MERKLEYE_HOOK_SECRET_FILE="$secret_file"
    run_hook
    [ "$status" -eq 0 ]
    [ "$(curl_call_count)" -eq 1 ]
    nth_curl_call 1 | grep -q "X-Merkleye-Hook-Secret: file-secret"
}

@test "hook.sh posts the shaped payload from certspotter's environment" {
    export MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    export MERKLEYE_HOOK_SECRET="testsecret"
    export EVENT="discovered_cert"
    export WATCH_ITEM="example.com"
    export LOG_URI="https://ct.example/log"
    export ENTRY_INDEX="42"
    export CERT_SHA256="deadbeef"
    export SUBJECT_DN="CN=example.com"
    export SUMMARY="matched watch item"

    run_hook
    [ "$status" -eq 0 ]
    [ "$(curl_call_count)" -eq 1 ]
    call="$(nth_curl_call 1)"
    echo "$call" | grep -q -- "-X"
    echo "$call" | grep -q "POST"
    echo "$call" | grep -q "http://backend/internal/v1/observations"
    echo "$call" | grep -q "X-Merkleye-Hook-Secret: testsecret"

    body="$(curl_call_body 1)"
    [ "$(echo "$body" | jq -r '.event')" = "discovered_cert" ]
    [ "$(echo "$body" | jq -r '.watch_item')" = "example.com" ]
    [ "$(echo "$body" | jq -r '.entry_index')" = "42" ]
    [ "$(echo "$body" | jq -r '.dns_names')" = "[]" ]
    [ "$(echo "$body" | jq -r '.cert_pem')" = "" ]
}

@test "hook.sh forwards dns_names from JSON_FILENAME" {
    export MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    export MERKLEYE_HOOK_SECRET="testsecret"
    json_file="$BATS_TEST_TMPDIR/cert.json"
    echo '{"dns_names":["example.com","www.example.com"]}' >"$json_file"
    export JSON_FILENAME="$json_file"

    run_hook
    [ "$status" -eq 0 ]
    body="$(curl_call_body 1)"
    [ "$(echo "$body" | jq -c '.dns_names')" = '["example.com","www.example.com"]' ]
}

@test "hook.sh falls back to an empty dns_names list on unparseable JSON_FILENAME" {
    export MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    export MERKLEYE_HOOK_SECRET="testsecret"
    json_file="$BATS_TEST_TMPDIR/cert.json"
    echo 'not json' >"$json_file"
    export JSON_FILENAME="$json_file"

    run_hook
    [ "$status" -eq 0 ]
    body="$(curl_call_body 1)"
    [ "$(echo "$body" | jq -r '.dns_names')" = "[]" ]
}

@test "hook.sh ignores an unreadable JSON_FILENAME" {
    export MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    export MERKLEYE_HOOK_SECRET="testsecret"
    export JSON_FILENAME="$BATS_TEST_TMPDIR/does-not-exist.json"

    run_hook
    [ "$status" -eq 0 ]
    body="$(curl_call_body 1)"
    [ "$(echo "$body" | jq -r '.dns_names')" = "[]" ]
}

@test "hook.sh forwards cert_pem when retention is enabled and CERT_FILENAME is readable" {
    export MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    export MERKLEYE_HOOK_SECRET="testsecret"
    retain_flag_setup
    touch "$RETAIN_FLAG"
    cert_file="$BATS_TEST_TMPDIR/cert.pem"
    printf 'fake-pem-bytes' >"$cert_file"
    export CERT_FILENAME="$cert_file"

    run_hook
    [ "$status" -eq 0 ]
    body="$(curl_call_body 1)"
    [ "$(echo "$body" | jq -r '.cert_pem')" = "$(base64 <"$cert_file" | tr -d '\n')" ]

    retain_flag_teardown
}

@test "hook.sh omits cert_pem when retention is enabled but CERT_FILENAME is unset" {
    export MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    export MERKLEYE_HOOK_SECRET="testsecret"
    retain_flag_setup
    touch "$RETAIN_FLAG"

    run_hook
    [ "$status" -eq 0 ]
    body="$(curl_call_body 1)"
    [ "$(echo "$body" | jq -r '.cert_pem')" = "" ]

    retain_flag_teardown
}

@test "hook.sh omits cert_pem when the retain flag is absent" {
    export MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    export MERKLEYE_HOOK_SECRET="testsecret"
    cert_file="$BATS_TEST_TMPDIR/cert.pem"
    printf 'fake-pem-bytes' >"$cert_file"
    export CERT_FILENAME="$cert_file"

    run_hook
    [ "$status" -eq 0 ]
    body="$(curl_call_body 1)"
    [ "$(echo "$body" | jq -r '.cert_pem')" = "" ]
}

@test "hook.sh propagates a curl failure" {
    export MERKLEYE_HOOK_URL="http://backend/internal/v1/observations"
    export MERKLEYE_HOOK_SECRET="testsecret"
    export MOCK_CURL_DEFAULT_EXIT=22

    run_hook
    [ "$status" -eq 22 ]
}

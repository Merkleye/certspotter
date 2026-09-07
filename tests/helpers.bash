# Shared bats setup for the certspotter test suite.

# mock_curl_setup — put the mock curl on PATH ahead of the real one and
# initialize its log + response queue. Call from every test's setup().
mock_curl_setup() {
    export PATH="$BATS_TEST_DIRNAME/bin:$PATH"
    export MOCK_CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
    export MOCK_CURL_QUEUE_DIR="$BATS_TEST_TMPDIR/curl-queue"
    mkdir -p "$MOCK_CURL_QUEUE_DIR"
    : >"$MOCK_CURL_LOG"
    MOCK_CURL_QUEUE_NEXT=1
}

# queue_curl_response EXIT_CODE [BODY_LINE...] — append one response to the
# mock curl's queue, consumed in the order queued.
queue_curl_response() {
    local exit_code="$1"
    shift
    local file
    file="$MOCK_CURL_QUEUE_DIR/$(printf '%03d' "$MOCK_CURL_QUEUE_NEXT")"
    MOCK_CURL_QUEUE_NEXT=$((MOCK_CURL_QUEUE_NEXT + 1))
    {
        echo "$exit_code"
        printf '%s\n' "$@"
    } >"$file"
}

# curl_call_count — how many curl invocations the mock has recorded so far.
curl_call_count() {
    grep -c '^MOCK_CURL_CALL$' "$MOCK_CURL_LOG" 2>/dev/null || true
}

# nth_curl_call N — print the Nth (1-based) recorded curl invocation's
# arguments, one per line, for assertions.
nth_curl_call() {
    awk -v n="$1" '
        /^MOCK_CURL_CALL$/ { count++; capturing = (count == n); next }
        /^MOCK_CURL_END$/  { capturing = 0; next }
        capturing          { print }
    ' "$MOCK_CURL_LOG"
}

# curl_call_body N — the request body of the Nth recorded curl call, whether
# it was passed as a "-d"/"--data" argument (hook.sh, healthcheck.sh) or
# piped in via "--data @-" (supervise.sh's report_status; see the mock
# curl's MOCK_CURL_STDIN marker). Exact-line matching against "-d"/"--data",
# not a substring grep, since flags like --retry-delay legitimately contain
# "-d". Prints every remaining line, not just the next one: the body is one
# shell word but jq's default pretty-printed output embeds newlines in it.
curl_call_body() {
    local block
    block="$(nth_curl_call "$1")"
    if printf '%s\n' "$block" | grep -qx 'MOCK_CURL_STDIN'; then
        printf '%s\n' "$block" | awk '/^MOCK_CURL_STDIN$/ { found = 1; next } found { print }'
    else
        printf '%s\n' "$block" | awk '$0 == "-d" || $0 == "--data" { found = 1; next } found { print }'
    fi
}

# retain_flag_setup / retain_flag_teardown — hook.sh's cert_pem forwarding is
# gated on a real, fixed filesystem path shared with the backend container
# (see hook.sh's own comment on retain_flag), not an env var, so exercising
# that branch means touching it directly. Created/removed per-test rather
# than left behind, since it is outside the repo's own tree.
#
# /var/lib is root-owned, so a plain `mkdir` only works when the test suite
# itself runs as root (true in some sandboxes, false on GitHub Actions'
# `runner` user) -- fall back to sudo, which that runner has passwordless,
# and leave the directory world-writable so later touch/rm calls in the
# test body (running as the same non-root user) don't each need sudo too.
retain_flag_setup() {
    RETAIN_FLAG=/var/lib/merkleye/retain_certificates
    if [ -d /var/lib/merkleye ]; then
        return 0
    fi
    mkdir -p /var/lib/merkleye 2>/dev/null || sudo mkdir -p /var/lib/merkleye
    chmod 1777 /var/lib/merkleye 2>/dev/null || sudo chmod 1777 /var/lib/merkleye
}

retain_flag_teardown() {
    rm -f /var/lib/merkleye/retain_certificates
}

# fake_certspotter_setup — put the fake certspotter binary on PATH ahead of
# any real one, for supervise.sh integration tests.
fake_certspotter_setup() {
    export PATH="$BATS_TEST_DIRNAME/bin:$PATH"
    export FAKE_CERTSPOTTER_LOG="$BATS_TEST_TMPDIR/certspotter.log"
    : >"$FAKE_CERTSPOTTER_LOG"
}

# wait_until CONDITION_CMD... — poll a condition (e.g. `wait_until test -f
# "$file"`) for up to $WAIT_UNTIL_MAX_ITER * 0.1s (default 50, i.e. 5s)
# before failing, instead of a fixed sleep. supervise.sh runs as a background
# process in integration tests, so its side effects (writing $watchlist,
# calling report_status) happen asynchronously.
wait_until() {
    local waited=0
    local max_iter="${WAIT_UNTIL_MAX_ITER:-50}"
    while ! "$@"; do
        waited=$((waited + 1))
        if [ "$waited" -ge "$max_iter" ]; then
            echo "wait_until: condition never became true: $*" >&2
            return 1
        fi
        sleep 0.1
    done
}

#!/bin/sh
# Keeps certspotter running against a current watchlist.
#
# certspotter parses -watchlist exactly once, at startup: cmd/certspotter's
# main reads the file (or stdin for "-") into config.WatchList before
# monitor.Run, and the only signals it handles are SIGINT and SIGTERM. There
# is no SIGHUP reload. So "the watchlist changed" can only mean "restart
# certspotter", and something has to notice the change and do the restart —
# that is this script.
#
# Before this existed, the backend rewrote a file on a shared volume after
# every domain change and nothing ever re-read it. A domain added through the
# API was live in the matcher immediately and invisible to the firehose until
# somebody happened to `docker compose restart certspotter`.
#
# The loop:
#
#   1. long-poll  GET /internal/v1/watchlist/version?since=<digest>&wait=…
#   2. on a new digest, page GET /internal/v1/watchlist?cursor=…&limit=…
#   3. verify the assembled file's sha256 against the digest
#   4. install it atomically and restart certspotter
#   5. report the cycle's outcome to the backend's hook
#
# Step 5 is what makes any of this observable. A sidecar that cannot reach the
# backend keeps watching its last known set and looks entirely healthy —
# process up, checkpoints advancing, hits still arriving for the domains it
# already had — so "the watchlist stopped updating" has no local symptom at
# all. One POST per cycle turns that into merkleye_certspotter_watchlist_*
# (see internal/health and ADR-0065); the signal to alert on is
# merkleye_certspotter_watchlist_last_success_timestamp going stale.
#
# Step 1 is a digest comparison, not an event subscription. Nothing is queued
# server-side, so an outage of any length on either end costs latency and
# nothing else: the first successful request after it returns the current
# digest, and if it differs we refetch the whole set. There is no backlog to
# replay and no cursor that can expire while we are gone.
#
# Step 3 is what makes a set that changed mid-pagination safe: the pages would
# assemble into a file that hashes to neither the old nor the new digest, so
# we discard it and start over rather than installing a watchlist that never
# existed.
set -u

: "${MERKLEYE_WATCHLIST_URL:?MERKLEYE_WATCHLIST_URL is required}"
: "${CERTSPOTTER_STATE_DIR:?CERTSPOTTER_STATE_DIR is required}"

MERKLEYE_WATCHLIST_VERSION_URL="${MERKLEYE_WATCHLIST_VERSION_URL:-${MERKLEYE_WATCHLIST_URL}/version}"
# Where the per-cycle status report goes. Optional and deliberately the same
# endpoint hook.sh and healthcheck.sh already post to, so there is one internal
# listener, one secret and one thing to firewall. Unset means "report nothing"
# — the supervisor still works, it is just invisible.
MERKLEYE_HOOK_URL="${MERKLEYE_HOOK_URL:-}"

# Same _FILE-first convention as hook.sh: prefer the secret file so the
# credential never sits in the environment of a container anyone can inspect.
#
# Required unconditionally, and not only when MERKLEYE_HOOK_URL is set: this
# same secret authenticates curl_auth, which is how the watchlist itself is
# fetched. Starting without it would mean every fetch 403s and certspotter
# never gets a watch set at all — a much worse failure than the missing status
# reports. It is the *reporting endpoint* that is optional, never the
# credential.
hook_secret="${MERKLEYE_HOOK_SECRET:-}"
if [ -n "${MERKLEYE_HOOK_SECRET_FILE:-}" ]; then
    hook_secret="$(cat "$MERKLEYE_HOOK_SECRET_FILE")"
fi
: "${hook_secret:?MERKLEYE_HOOK_SECRET or MERKLEYE_HOOK_SECRET_FILE is required}"

# The watchlist lives in the persistent state volume next to certspotter's
# checkpoints, so a restart while the backend is unreachable still comes up
# watching the last known set instead of nothing at all.
watchlist="$CERTSPOTTER_STATE_DIR/watchlist.txt"
watchlist_prev="$CERTSPOTTER_STATE_DIR/watchlist.prev.txt"
digest_file="$CERTSPOTTER_STATE_DIR/watchlist.digest"

# How long the version endpoint holds a request open with no change. The
# backend caps this independently; asking for more just gets the cap.
wait_for="${MERKLEYE_WATCHLIST_WAIT:-30s}"
# Backoff between cycles after a failed request. Deliberately short: the
# backend being briefly unreachable is the common case (a restart, a
# redeploy), not an outage worth backing off minutes for.
retry_interval="${MERKLEYE_WATCHLIST_RETRY_INTERVAL:-15}"
# Floor on how often certspotter may be restarted. Each restart is a real
# cost — in-flight log fetches are dropped and resumed from the last
# checkpoint — so a burst of API edits (a bulk import, a variant set
# regenerating per-domain) coalesces into one restart instead of dozens.
min_restart_interval="${MERKLEYE_WATCHLIST_MIN_RESTART_INTERVAL:-30}"
page_limit="${MERKLEYE_WATCHLIST_PAGE_LIMIT:-5000}"
# Refuse to page forever if the server keeps handing back a cursor. At the
# default page size this is 5M entries, far past any real watch set.
max_pages="${MERKLEYE_WATCHLIST_MAX_PAGES:-1000}"
# A watchlist certspotter rejects (an unparseable line) makes it exit(1) at
# startup. If it dies within this many seconds of a swap, we treat the new
# watchlist as the cause and roll back — one bad generated name must not be
# able to take the firehose down permanently.
settle_seconds="${MERKLEYE_WATCHLIST_SETTLE_SECONDS:-10}"

cs_pid=""
last_restart=0
# The digest of a set certspotter refused, if we are still running the previous
# one because of it. current_digest deliberately stays pinned to that digest so
# the next poll compares equal and we do not refetch and re-break on every
# cycle — but "equal" then means "the backend is still serving the set we could
# not install", which is not the same as being in sync with it. Without this,
# the very next unchanged cycle reported in_sync=true and the one condition
# that needs a human disappeared from the metrics about 30 seconds after it
# started.
rejected_digest=""


log() { echo "supervise: $*" >&2; }

# report_status OUTCOME [DIGEST] [IN_SYNC] [SUMMARY] — tell the backend how
# this cycle went.
#
# Best-effort in exactly the way healthcheck.sh's heartbeat is: the whole point
# of this report is to make a backend the sidecar cannot reach visible, so a
# failure to deliver it must never change what the supervisor does next. It is
# also why the failure path posts nothing rather than retrying — the missing
# report *is* the signal.
#
# entries is counted off the installed file rather than taken from the version
# response, so it says what certspotter is actually running against and can be
# compared with the backend's own merkleye_watchlist_entries.
report_status() {
    [ -n "$MERKLEYE_HOOK_URL" ] || return 0
    _outcome="$1"
    _digest="${2:-}"
    _in_sync="${3:-false}"
    _summary="${4:-}"
    _entries=0
    [ -f "$watchlist" ] && _entries="$(wc -l < "$watchlist" | tr -d ' ')"
    jq -nc \
        --arg outcome "$_outcome" \
        --arg digest "$_digest" \
        --arg summary "$_summary" \
        --argjson entries "${_entries:-0}" \
        --argjson in_sync "$_in_sync" \
        '{event:"watchlist_status", outcome:$outcome, digest:$digest,
          entries:$entries, in_sync:$in_sync, summary:$summary}' |
        curl --silent --show-error --fail --max-time 5 \
            -X POST "$MERKLEYE_HOOK_URL" \
            -H 'Content-Type: application/json' \
            -H "X-Merkleye-Hook-Secret: $hook_secret" \
            --data @- >/dev/null 2>&1 ||
        log "watchlist status POST failed (non-fatal)"
}

# certspotter_alive — is the child still running?
#
# Not `kill -0`: a child that has exited but not yet been reaped is a zombie,
# and kill -0 succeeds on a zombie. Whether the shell reaps a background job
# on its own before we ask is implementation-defined, so the liveness check
# reads the process state out of /proc and treats Z as dead. The sed pattern
# starts after the last ')' because /proc/PID/stat's comm field is
# parenthesized and may itself contain spaces or parens.
certspotter_alive() {
    [ -n "$cs_pid" ] || return 1
    _state="$(sed -n 's/^.*) \([A-Za-z]\).*/\1/p' "/proc/$cs_pid/stat" 2>/dev/null)"
    [ -n "$_state" ] && [ "$_state" != "Z" ]
}

curl_auth() {
    curl --silent --show-error --fail-with-body \
        -H "X-Merkleye-Hook-Secret: $hook_secret" "$@"
}

# fetch_watchlist PATH — page the watchlist into PATH. Returns non-zero and
# leaves PATH in an unspecified state on any failure; callers write to a temp
# file and only install it after verify_digest agrees.
fetch_watchlist() {
    _out="$1"
    _cursor=""
    _pages=0
    : > "$_out" || return 1
    while :; do
        _pages=$((_pages + 1))
        if [ "$_pages" -gt "$max_pages" ]; then
            log "watchlist pagination exceeded $max_pages pages; giving up"
            return 1
        fi
        _url="${MERKLEYE_WATCHLIST_URL}?limit=${page_limit}"
        if [ -n "$_cursor" ]; then
            _url="${_url}&cursor=${_cursor}"
        fi
        _body="$(curl_auth --max-time 60 "$_url")" || return 1
        # -r so entries land as raw lines, which is the file format; jq
        # fails loudly on a body that is not the expected shape rather than
        # silently writing an empty page.
        printf '%s' "$_body" | jq -er '.entries[]?' >> "$_out"
        case $? in
            0) ;;
            # jq -e exits 1 when the last output was null/false and 4 when
            # there was no output at all. An empty page is legitimate (an
            # empty watch set, or an exactly-full previous page), so only a
            # real parse error (5) or usage error is fatal here.
            4) ;;
            *) log "failed to parse watchlist page $_pages"; return 1 ;;
        esac
        _cursor="$(printf '%s' "$_body" | jq -r '.next_cursor // ""')" || return 1
        [ -n "$_cursor" ] || break
    done
    return 0
}

# verify_digest PATH DIGEST — the file must hash to exactly what the backend
# said the whole set hashes to. The backend hashes every entry newline-
# terminated in the same byte order it pages them, so this is a plain
# sha256sum with no normalization on either side.
verify_digest() {
    _local="$(sha256sum "$1" | cut -d' ' -f1)"
    [ "$_local" = "$2" ]
}

start_certspotter() {
    # -start_at_end applies only to logs with no saved state, so a restart
    # here resumes from the checkpoints in $CERTSPOTTER_STATE_DIR rather than
    # skipping to the tip. That is the whole reason that directory is a named
    # volume (see the Containerfile).
    certspotter \
        -watchlist "$watchlist" \
        -state_dir "$CERTSPOTTER_STATE_DIR" \
        -script /usr/local/bin/merkleye-hook.sh \
        -start_at_end \
        -no_save \
        -verbose &
    cs_pid=$!
    last_restart="$(date +%s)"
    log "certspotter started (pid $cs_pid, $(wc -l < "$watchlist") watchlist entries)"
}

stop_certspotter() {
    [ -n "$cs_pid" ] || return 0
    kill -TERM "$cs_pid" 2>/dev/null
    _waited=0
    while certspotter_alive; do
        [ "$_waited" -ge 15 ] && { log "certspotter did not exit in 15s; killing"; kill -KILL "$cs_pid" 2>/dev/null; break; }
        sleep 1
        _waited=$((_waited + 1))
    done
    wait "$cs_pid" 2>/dev/null
    cs_pid=""
}

# restart_certspotter — swap in the new watchlist and bounce the child,
# rolling back if the new list is one certspotter refuses to parse.
restart_certspotter() {
    _now="$(date +%s)"
    _since="$((_now - last_restart))"
    if [ "$last_restart" -ne 0 ] && [ "$_since" -lt "$min_restart_interval" ]; then
        _sleep="$((min_restart_interval - _since))"
        log "coalescing restart; waiting ${_sleep}s"
        sleep "$_sleep"
    fi

    stop_certspotter
    start_certspotter

    # certspotter validates the whole watchlist before it starts monitoring,
    # so a parse failure shows up as an immediate exit rather than a bad
    # match later.
    _elapsed=0
    while [ "$_elapsed" -lt "$settle_seconds" ]; do
        if ! certspotter_alive; then
            log "certspotter exited ${_elapsed}s after a watchlist swap"
            if [ -f "$watchlist_prev" ]; then
                log "rolling back to the previous watchlist"
                cp "$watchlist_prev" "$watchlist"
                # Drop the recorded digest: the installed file is the old set
                # again, so the next poll must see a difference and refetch
                # rather than believing it already has the new one.
                rm -f "$digest_file"
                start_certspotter
                return 1
            fi
            log "no previous watchlist to roll back to"
            return 1
        fi
        sleep 1
        _elapsed=$((_elapsed + 1))
    done
    return 0
}

shutdown() {
    log "shutting down"
    stop_certspotter
    exit 0
}
trap shutdown TERM INT

# --- boot ------------------------------------------------------------------
#
# Never start certspotter against a watchlist we have no reason to trust: on
# a cold start with an unreachable backend we retry rather than watching an
# empty set, which would look healthy (process up, checkpoints advancing) and
# silently match nothing. With a watchlist already on the state volume we do
# start immediately, because watching a slightly stale set beats watching
# none while the backend comes back.
current_digest=""
[ -f "$digest_file" ] && current_digest="$(cat "$digest_file")"

if [ ! -f "$watchlist" ]; then
    log "no watchlist on disk; fetching before starting certspotter"
    while :; do
        version="$(curl_auth --max-time 30 "$MERKLEYE_WATCHLIST_VERSION_URL")" || {
            log "backend unreachable; retrying in ${retry_interval}s"
            report_status fetch_failed "" false "backend unreachable on initial fetch"
            sleep "$retry_interval"; continue
        }
        digest="$(printf '%s' "$version" | jq -r '.digest')"
        tmp="${watchlist}.tmp.$$"
        if fetch_watchlist "$tmp" && verify_digest "$tmp" "$digest"; then
            mv "$tmp" "$watchlist"
            printf '%s\n' "$digest" > "$digest_file"
            current_digest="$digest"
            report_status synced "$digest" true
            break
        fi
        rm -f "$tmp"
        log "initial watchlist fetch failed or changed mid-fetch; retrying in ${retry_interval}s"
        report_status verify_failed "$digest" false "initial fetch failed or changed mid-fetch"
        sleep "$retry_interval"
    done
fi

start_certspotter

# --- refresh loop ----------------------------------------------------------
while :; do
    # A child that died on its own (a crash, an unrecoverable log error) is
    # not this script's to diagnose: exit and let the container's restart
    # policy take it from the top, the same as before this supervisor existed.
    if ! certspotter_alive; then
        wait "$cs_pid" 2>/dev/null
        rc=$?
        log "certspotter exited unexpectedly (status $rc); exiting so the container restarts"
        exit "$rc"
    fi

    version="$(curl_auth --max-time 120 \
        "${MERKLEYE_WATCHLIST_VERSION_URL}?since=${current_digest}&wait=${wait_for}")" || {
        report_status fetch_failed "$current_digest" false "version request failed"
        sleep "$retry_interval"
        continue
    }
    digest="$(printf '%s' "$version" | jq -r '.digest')"
    if [ -z "$digest" ] || [ "$digest" = "null" ]; then
        log "version response had no digest; retrying in ${retry_interval}s"
        report_status fetch_failed "$current_digest" false "version response had no digest"
        sleep "$retry_interval"
        continue
    fi
    # The common case, and the one worth reporting loudest: the backend
    # answered and we already have what it is serving. This is the report that
    # keeps last_success advancing while nothing is changing.
    if [ "$digest" = "$current_digest" ]; then
        if [ -n "$rejected_digest" ] && [ "$digest" = "$rejected_digest" ]; then
            # Equal digests, but only because we pinned ours to the set
            # certspotter would not take. What is running is the previous
            # watchlist, so keep saying so every cycle until either the
            # operator fixes the offending name or the backend serves
            # something else.
            report_status rejected "$digest" false \
                "still running the previous set; watchlist ${digest} was rejected"
        else
            report_status unchanged "$digest" true
        fi
        continue
    fi

    total="$(printf '%s' "$version" | jq -r '.total')"
    log "watchlist changed (${total} entries, digest ${digest}); refetching"

    tmp="${watchlist}.tmp.$$"
    if ! fetch_watchlist "$tmp"; then
        rm -f "$tmp"
        report_status fetch_failed "$digest" false "paging the watchlist failed"
        sleep "$retry_interval"
        continue
    fi
    if ! verify_digest "$tmp" "$digest"; then
        # The set changed while we were paging. Not an error — just start over;
        # the next version call returns the newer digest immediately.
        rm -f "$tmp"
        log "watchlist changed mid-fetch; retrying"
        report_status verify_failed "$digest" false "watchlist changed mid-fetch"
        continue
    fi

    cp "$watchlist" "$watchlist_prev" 2>/dev/null
    mv "$tmp" "$watchlist"
    printf '%s\n' "$digest" > "$digest_file"
    current_digest="$digest"

    if ! restart_certspotter; then
        # Rolled back. current_digest is deliberately left pointing at the
        # rejected set's digest so the next poll compares equal and we do not
        # immediately refetch and re-break; the digest file was removed, so a
        # container restart re-tries it once, and the report below is what an
        # operator acts on. in_sync is false because what certspotter is
        # running is not what the backend is serving — which is exactly the
        # state that has no other symptom.
        log "watchlist ${digest} was rejected by certspotter; staying on the previous set"
        rejected_digest="$digest"
        report_status rejected "$digest" false "certspotter exited after the swap; rolled back"
        continue
    fi
    # Installed and survived the settle window, so whatever was rejected before
    # is behind us — a later poll must not keep reporting a set we are no
    # longer stuck on.
    rejected_digest=""
    report_status synced "$digest" true
done

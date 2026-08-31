#!/bin/sh
# Docker HEALTHCHECK + liveness heartbeat for the certspotter sidecar.
#
# Two checks decide the exit code: the certspotter process is running, and
# files under $CERTSPOTTER_STATE_DIR have been touched recently. The second
# is a heuristic — it assumes certspotter's per-log checkpoint files update on
# a roughly-continuous cadence independent of watchlist matches, which was not
# independently verified against the pinned certspotter version as part of
# adding this script. Confirm it holds for your log set before trusting the
# default threshold in production (same caveat as the SSLMate backfill
# assumptions in internal/ingest/sslmate/sslmate.go).
#
# On success, also POSTs a heartbeat to the backend so the ingestion watchdog
# can tell "no watchlist matches yet" apart from "the sidecar is dead" — see
# internal/health. A failed heartbeat POST must never fail this healthcheck:
# a backend restart is not a reason for autoheal to restart certspotter too.
#
# It also POSTs a log_status event carrying every log's checkpoint from
# $CERTSPOTTER_STATE_DIR/logs/*/state.json — download_position vs
# verified_position is real backlog (fetched but not yet verified against a
# signed tree head), and errors/<date> holds the most recent per-log error.
# This is what backs GET /plugins/{id}. Same best-effort contract as the
# heartbeat above: a failure here never fails the healthcheck.
set -u

: "${CERTSPOTTER_STATE_DIR:?CERTSPOTTER_STATE_DIR is required}"
stale_minutes="${MERKLEYE_HEALTHCHECK_STALE_MINUTES:-10}"

if ! pgrep -x certspotter >/dev/null 2>&1; then
    echo "healthcheck: certspotter process not running" >&2
    exit 1
fi

if [ -z "$(find "$CERTSPOTTER_STATE_DIR" -type f -mmin "-${stale_minutes}" 2>/dev/null)" ]; then
    echo "healthcheck: no checkpoint activity under $CERTSPOTTER_STATE_DIR in ${stale_minutes}m" >&2
    exit 1
fi

hook_secret=""
if [ -n "${MERKLEYE_HOOK_URL:-}" ]; then
    hook_secret="${MERKLEYE_HOOK_SECRET:-}"
    if [ -n "${MERKLEYE_HOOK_SECRET_FILE:-}" ]; then
        hook_secret="$(cat "$MERKLEYE_HOOK_SECRET_FILE" 2>/dev/null || true)"
    fi
fi

# Heartbeat is best-effort: reuse hook.sh's auth pattern, but never let a
# backend hiccup turn into a false-negative healthcheck.
if [ -n "${MERKLEYE_HOOK_URL:-}" ] && [ -n "$hook_secret" ]; then
    curl --silent --show-error --fail --max-time 5 \
        -X POST "$MERKLEYE_HOOK_URL" \
        -H 'Content-Type: application/json' \
        -H "X-Merkleye-Hook-Secret: $hook_secret" \
        -d '{"event":"heartbeat"}' \
        >/dev/null 2>&1 || echo "healthcheck: heartbeat POST failed (non-fatal)" >&2

    logs_dir="$CERTSPOTTER_STATE_DIR/logs"
    if [ -d "$logs_dir" ]; then
        logs_json="$(
            for d in "$logs_dir"/*/; do
                [ -d "$d" ] || continue
                log_id="$(basename "$d")"
                state_file="${d}state.json"
                [ -r "$state_file" ] || continue

                last_error=""
                last_error_at=""
                errors_dir="${d}errors"
                if [ -d "$errors_dir" ]; then
                    latest_error_file="$(ls -t "$errors_dir" 2>/dev/null | head -n1)"
                    if [ -n "$latest_error_file" ] && [ -r "$errors_dir/$latest_error_file" ]; then
                        last_line="$(tail -n1 "$errors_dir/$latest_error_file" 2>/dev/null)"
                        last_error_at="${last_line%% *}"
                        last_error="${last_line#* }"
                    fi
                fi

                jq -c \
                    --arg log_id "$log_id" \
                    --arg last_error "$last_error" \
                    --arg last_error_at "$last_error_at" \
                    '{
                        log_id: $log_id,
                        checkpoint_size: (.verified_position.size // 0),
                        checkpoint_at: (if .verified_sth.timestamp
                            then (.verified_sth.timestamp / 1000 | floor | todate)
                            else (.last_success // "") end),
                        download_size: (.download_position.size // 0),
                        last_error: $last_error,
                        last_error_at: $last_error_at
                    }' "$state_file" 2>/dev/null
            done | jq -s -c '.'
        )"
        if [ -n "$logs_json" ] && [ "$logs_json" != "[]" ]; then
            curl --silent --show-error --fail --max-time 10 \
                -X POST "$MERKLEYE_HOOK_URL" \
                -H 'Content-Type: application/json' \
                -H "X-Merkleye-Hook-Secret: $hook_secret" \
                -d "$(jq -c -n --argjson logs "$logs_json" '{event:"log_status", logs:$logs}')" \
                >/dev/null 2>&1 || echo "healthcheck: log_status POST failed (non-fatal)" >&2
        fi
    fi
fi

exit 0

#!/bin/sh
# certspotter script hook → Merkleye backend.
#
# certspotter execs this with the event described entirely in the environment
# (see certspotter-script(8)). This script's only job is to reshape those
# variables into JSON and POST them to the backend's internal endpoint.
#
# Deliberately dependency-light: it runs once per discovered certificate, so it
# stays a shell script with jq rather than growing into a program.
set -eu

: "${MERKLEYE_HOOK_URL:?MERKLEYE_HOOK_URL is required}"

# The shared secret authenticates this hook to the backend. Prefer the _FILE
# form so the secret never appears in the process environment of a container
# anyone can inspect.
if [ -n "${MERKLEYE_HOOK_SECRET_FILE:-}" ]; then
    MERKLEYE_HOOK_SECRET="$(cat "$MERKLEYE_HOOK_SECRET_FILE")"
fi
: "${MERKLEYE_HOOK_SECRET:?MERKLEYE_HOOK_SECRET or MERKLEYE_HOOK_SECRET_FILE is required}"

# DNS names live in the JSON file certspotter writes, not in the environment.
dns_names="[]"
if [ -n "${JSON_FILENAME:-}" ] && [ -r "${JSON_FILENAME:-}" ]; then
    dns_names="$(jq -c '.dns_names // []' "$JSON_FILENAME" 2>/dev/null || echo '[]')"
fi

# CERT_FILENAME is the PEM-encoded certificate certspotter wrote to disk for
# this discovery. Forwarding it is what lets the backend serve GET
# .../pem later; it costs nothing extra to read here since certspotter
# already dropped the file for us.
#
# Whether to bother is decided by ingest.retain_certificates in the backend's
# own config.yaml, not a second setting here — config.yaml is the sole write
# authority (DESIGN G-05), and a compose-level env var duplicating this would
# just let the two drift. certspotter.WriteRetentionFlag drops a flag file
# next to the watchlist on the same shared volume this container already
# mounts read-only for that watchlist, so this hook checks for the file
# instead of an env var. Missing file (retention off, or backend predates
# this flag) means the same thing either way: don't send cert_pem.
cert_pem=""
# /var/lib/merkleye is the fixed mount point of the "shared" volume in both
# docker-compose.yml and docker-compose.local.yml — the same one this
# container already reads its watchlist from.
retain_flag="/var/lib/merkleye/retain_certificates"
if [ -f "$retain_flag" ] && [ -n "${CERT_FILENAME:-}" ] && [ -r "${CERT_FILENAME:-}" ]; then
    cert_pem="$(base64 < "$CERT_FILENAME" | tr -d '\n')"
fi

payload="$(jq -n \
    --arg event         "${EVENT:-}" \
    --arg watch_item    "${WATCH_ITEM:-}" \
    --arg log_uri       "${LOG_URI:-}" \
    --arg entry_index   "${ENTRY_INDEX:-}" \
    --arg cert_sha256   "${CERT_SHA256:-}" \
    --arg tbs_sha256    "${TBS_SHA256:-}" \
    --arg pubkey_sha256 "${PUBKEY_SHA256:-}" \
    --arg subject_dn    "${SUBJECT_DN:-}" \
    --arg issuer_dn     "${ISSUER_DN:-}" \
    --arg serial        "${SERIAL:-}" \
    --arg not_before    "${NOT_BEFORE_RFC3339:-}" \
    --arg not_after     "${NOT_AFTER_RFC3339:-}" \
    --arg summary       "${SUMMARY:-}" \
    --arg parse_error   "${PARSE_ERROR:-}" \
    --arg leaf_hash     "${LEAF_HASH:-}" \
    --arg cert_pem      "$cert_pem" \
    --argjson dns_names "$dns_names" \
    '{
        event: $event, watch_item: $watch_item,
        log_uri: $log_uri, entry_index: $entry_index,
        cert_sha256: $cert_sha256, tbs_sha256: $tbs_sha256, pubkey_sha256: $pubkey_sha256,
        subject_dn: $subject_dn, issuer_dn: $issuer_dn, serial: $serial,
        not_before: $not_before, not_after: $not_after,
        dns_names: $dns_names,
        summary: $summary, parse_error: $parse_error, leaf_hash: $leaf_hash,
        cert_pem: $cert_pem
    }')"

# --fail-with-body surfaces the backend's rejection reason in certspotter's log
# instead of a bare exit code. Retries cover a backend restart; beyond that,
# failing loudly is correct — a silently dropped certificate is the one failure
# mode this whole project exists to prevent.
curl --silent --show-error --fail-with-body \
    --retry 3 --retry-delay 2 --retry-connrefused \
    --max-time 30 \
    -X POST "$MERKLEYE_HOOK_URL" \
    -H 'Content-Type: application/json' \
    -H "X-Merkleye-Hook-Secret: $MERKLEYE_HOOK_SECRET" \
    -d "$payload"

#!/usr/bin/env bash
# Print per-line coverage for this repo's own scripts from a bashcov run,
# and fail if any of them has a line bashcov considers coverable but never
# hit. Reads coverage/coverage.json (SimpleCov's own report, which already
# applies `# simplecov:disable`/`# simplecov:enable` exclusions) rather than
# the raw .resultset.json, and only looks at this repo's own scripts --
# bashcov's run also instruments bats' own internals and the mock binaries
# under tests/bin, which aren't part of what this checks.
set -eu

cd "$(dirname "$0")/.."

targets="hook.sh healthcheck.sh supervise.sh"
ok=0

for target in $targets; do
    info="$(jq -c --arg t "$target" '
        (.coverage // .) | to_entries[]
        | select((.key | split("/") | last) == $t)
        | .value
    ' coverage/coverage.json | head -n1)"

    if [ -z "$info" ]; then
        echo "$target: NOT FOUND in coverage report"
        ok=1
        continue
    fi

    missed="$(echo "$info" | jq -r '.missed_lines')"
    total="$(echo "$info" | jq -r '.total_lines')"
    pct="$(echo "$info" | jq -r '.lines_covered_percent')"
    covered=$((total - missed))
    printf '%s: %s%% (%d/%d coverable lines)\n' "$target" "$pct" "$covered" "$total"

    if [ "$missed" -gt 0 ]; then
        ok=1
        echo "$info" | jq -r '
            .source as $src | .lines as $lines
            | range(0; ($lines | length))
            | select($lines[.] == 0)
            | "  line \(. + 1): NOT COVERED: \($src[.])"
        '
    fi
done

exit "$ok"

#!/usr/bin/env bash
# Copies PROTOCOL.md, PLAN.md and protocol/fixtures/ from the receiver repo
# (the source of truth) and fails if anything still differs afterwards.
#
#   scripts/sync-protocol.sh <path-to-imac-display-receiver>
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <path-to-imac-display-receiver>" >&2
    exit 2
fi

SRC="$(cd "$1" && pwd)"
DST="$(cd "$(dirname "$0")/.." && pwd)"

for required in PROTOCOL.md PLAN.md protocol/fixtures; do
    if [[ ! -e "$SRC/$required" ]]; then
        echo "error: $SRC/$required not found; is $SRC the receiver repo?" >&2
        exit 1
    fi
done

cp "$SRC/PROTOCOL.md" "$DST/PROTOCOL.md"
cp "$SRC/PLAN.md" "$DST/PLAN.md"
mkdir -p "$DST/protocol/fixtures"
# Mirror exactly: fixtures deleted upstream must disappear here too.
rm -f "$DST"/protocol/fixtures/*.bin
cp "$SRC"/protocol/fixtures/*.bin "$DST/protocol/fixtures/"

status=0
for file in PROTOCOL.md PLAN.md; do
    if ! cmp -s "$SRC/$file" "$DST/$file"; then
        echo "error: $file differs after copy" >&2
        status=1
    fi
done
if ! diff -r "$SRC/protocol/fixtures" "$DST/protocol/fixtures" >/dev/null; then
    echo "error: protocol/fixtures differ after copy:" >&2
    diff -rq "$SRC/protocol/fixtures" "$DST/protocol/fixtures" >&2 || true
    status=1
fi

if [[ $status -eq 0 ]]; then
    echo "protocol files in sync with $SRC"
    echo "next: swift test (fixtures must still round-trip)"
fi
exit $status

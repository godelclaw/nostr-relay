#!/usr/bin/env bash
# scripts/relay-status's parsers on fixtures: the allowlist from config.toml, the sign-ins
# and the loaded-key count from the relay log, the prefix -> name lookup. No docker: the
# docker-backed sections are exercised on the relay host by running the script itself.
#
#   tests/relay-status.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../scripts/relay-status
. "$HERE/scripts/relay-status"            # defines the functions; main does not run when sourced

pass=0; failn=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"
    else failn=$((failn+1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

A=$(printf 'a%063x' 1); B=$(printf 'b%063x' 2); C=$(printf 'c%063x' 3)   # distinct 12-hex prefixes, as real keys have
cat > "$T/config.toml" <<CONF
[gate]
relay_urls = [ "ws://nostr-relay:8080" ]
[authorization]
pubkey_whitelist = [
  "$A",  # alpha
  "$B",  # beta-two
  "$C",
]
# "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",  # after the block, ignored
CONF
check "allowlist: hex + name, '-' when no comment, nothing outside the block" \
    "$A alpha
$B beta-two
$C -" \
    "$(allowlist_from_config < "$T/config.toml")"

# the real file in the repo parses to the same count as its quoted keys
check "allowlist: repo config.toml, every key named" \
    "$(grep -c '^  "[0-9a-f]\{64\}"' "$HERE/config.toml") 0" \
    "$(allowlist_from_config < "$HERE/config.toml" | awk '{ n++; if ($2 == "-") u++ } END { print n+0, u+0 }')"

LOG="2026-10-25 20:00:01,123 INFO listening on 0.0.0.0:8080, 3 key(s) on the allowlist
2026-10-25 20:00:05,000 INFO auth ok: ${A:0:12}
2026-10-25 20:00:06,000 INFO auth refused (${C:0:12}): not on the allowlist
2026-10-25 20:00:07,000 INFO auth refused (?): malformed AUTH event
2026-10-25 20:01:00,000 INFO config reloaded: 4 key(s) on the allowlist
2026-10-25 20:02:00,000 INFO auth ok: ${B:0:12}
2026-10-25 20:02:01,000 INFO deletion by ${A:0:12}: 1 event(s) removed"
check "sign-ins: ok and refused with the reason, nothing else" \
    "ok ${A:0:12}
refused ${C:0:12} not on the allowlist
refused ? malformed AUTH event
ok ${B:0:12}" \
    "$(printf '%s\n' "$LOG" | signins_from_log)"
check "loaded count: the last reload wins over the start line" "4" "$(printf '%s\n' "$LOG" | loaded_count_from_log)"
check "loaded count: start line alone" "3" "$(printf '%s\n' "$LOG" | head -1 | loaded_count_from_log)"
check "loaded count: empty log -> empty" "" "$(printf '' | loaded_count_from_log)"

allowlist_from_config < "$T/config.toml" > "$T/names"
check "name_of: 12-hex prefix" "beta-two" "$(name_of "$T/names" "${B:0:12}")"
check "name_of: full hex" "alpha" "$(name_of "$T/names" "$A")"
check "name_of: unknown key" "(not on the allowlist)" "$(name_of "$T/names" "deadbeefdead")"
check "name_of: '?' from a malformed AUTH" "(not on the allowlist)" "$(name_of "$T/names" "?")"

echo; echo "$pass passed, $failn failed"
[ "$failn" = 0 ]

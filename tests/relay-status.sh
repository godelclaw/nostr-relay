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

# the edges the relay handles (tomllib, lowercased, deduped) and a hand edit produce
cat > "$T/empty.toml" <<CONF
[authorization]
pubkey_whitelist = []
[other]
note = "$A"  # a key elsewhere is not on the allowlist
CONF
check "allowlist: '[]' on one line closes the block" "" "$(allowlist_from_config < "$T/empty.toml")"
cat > "$T/edges.toml" <<CONF
  [authorization]
  pubkey_whitelist = [
    "$A",  # alpha
    #  "$B",  # revoked by hand
    "$(printf '%s' "$C" | tr a-f A-F)",  # Charlie Three
    "$A"  # alpha again, no comma
    ]
CONF
check "allowlist: commented-out key skipped, uppercase lowered, duplicate once, indented, spaces in a name" \
    "$A alpha
$C Charlie Three" \
    "$(allowlist_from_config < "$T/edges.toml")"

# the real file in the repo parses to the same count as its quoted keys
check "allowlist: repo config.toml, every key named" \
    "$(grep -c '^  "[0-9a-f]\{64\}"' "$HERE/config.toml") 0" \
    "$(allowlist_from_config < "$HERE/config.toml" | awk '{ n++; if ($2 == "-") u++ } END { print n+0, u+0 }')"

LOG="2026-10-25 20:00:01,123 INFO listening on 0.0.0.0:8080, 3 key(s) on the allowlist
2026-10-25 20:00:05,000 INFO auth ok: ${A:0:12}
2026-10-25 20:00:06,000 INFO auth refused (${C:0:12}): restricted: this key is not on the allowlist
2026-10-25 20:00:07,000 INFO auth refused (?): invalid: not an AUTH event
2026-10-25 20:00:08,000 INFO auth refused (): invalid: id, pubkey or sig malformed
2026-10-25 20:00:09,000 INFO auth refused (0): invalid: id, pubkey or sig malformed
2026-10-25 20:00:09,500 INFO auth refused ($(printf '\033')[2J$(printf '\033')[H): invalid: id, pubkey or sig malformed
2026-10-25 20:00:09,700 INFO auth refused (a)b): invalid: id, pubkey or sig malformed
2026-10-25 20:00:10,000 INFO auth refused (${C:0:12}): invalid: AUTH event too old or in the future
2026-10-25 20:00:11,000 INFO auth refused (${C:0:12}): restricted: this key is not on the allowlist
2026-10-25 20:01:00,000 INFO config reloaded: 4 key(s) on the allowlist
2026-10-25 20:02:00,000 INFO auth ok: ${B:0:12}
2026-10-25 20:02:01,000 INFO deletion by ${A:0:12}: 1 event(s) removed"
check "sign-ins: ok and refused with the whole reason; any prefix but 12 hex or ? is (malformed)" \
    "ok ${A:0:12}
refused ${C:0:12} restricted: this key is not on the allowlist
refused ? invalid: not an AUTH event
refused (malformed) invalid: id, pubkey or sig malformed
refused (malformed) invalid: id, pubkey or sig malformed
refused (malformed) invalid: id, pubkey or sig malformed
refused (malformed) invalid: id, pubkey or sig malformed
refused ${C:0:12} invalid: AUTH event too old or in the future
refused ${C:0:12} restricted: this key is not on the allowlist
ok ${B:0:12}" \
    "$(printf '%s\n' "$LOG" | signins_from_log)"
check "summary: counted per key and whole reason, ok first, most frequent first, then by key" \
    "ok ${A:0:12} 1
ok ${B:0:12} 1
refused (malformed) 4 invalid: id, pubkey or sig malformed
refused ${C:0:12} 2 restricted: this key is not on the allowlist
refused ? 1 invalid: not an AUTH event
refused ${C:0:12} 1 invalid: AUTH event too old or in the future" \
    "$(printf '%s\n' "$LOG" | signins_from_log | signins_summary)"
check "loaded count: the last reload wins over the start line" "4" "$(printf '%s\n' "$LOG" | loaded_count_from_log)"
check "loaded count: start line alone" "3" "$(printf '%s\n' "$LOG" | head -1 | loaded_count_from_log)"
check "loaded count: empty log -> empty" "" "$(printf '' | loaded_count_from_log)"

allowlist_from_config < "$T/config.toml" > "$T/names"
check "name_of: 12-hex prefix" "beta-two" "$(name_of "$T/names" "${B:0:12}")"
check "name_of: full hex" "alpha" "$(name_of "$T/names" "$A")"
check "name_of: unknown key" "(not on the allowlist)" "$(name_of "$T/names" "deadbeefdead")"
check "name_of: '?' from a malformed AUTH" "(not on the allowlist)" "$(name_of "$T/names" "?")"
check "name_of: a short hex prefix never matches a key" "(not on the allowlist)" "$(name_of "$T/names" "${A:0:1}")"
allowlist_from_config < "$T/edges.toml" > "$T/names2"
check "name_of: a name with spaces, whole" "Charlie Three" "$(name_of "$T/names2" "${C:0:12}")"

echo; echo "$pass passed, $failn failed"
[ "$failn" = 0 ]

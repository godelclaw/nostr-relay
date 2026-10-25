#!/usr/bin/env bash
# scripts/sync-allowlist on a fixture config.toml and keys directory: it reads the public
# keys from KEYS_DIR, rewrites only the block, and refuses to drop a key it was not told to.
#
#   tests/sync-allowlist.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SA="$HERE/scripts/sync-allowlist"

pass=0; failn=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"
    else failn=$((failn+1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

A=$(printf 'a%063x' 1); B=$(printf 'b%063x' 2); C=$(printf 'c%063x' 3); D=$(printf 'd%063x' 4)
key() { mkdir -p "$T/keys/$1"; printf '%s\n' "$2" > "$T/keys/$1/nostr-pubkey-hex"; }
key alpha "$A"; key beta "$B"; key gamma "$C"; key delta "$D"
fixture() {
    cat > "$T/config.toml" <<CONF
[authorization]
pubkey_whitelist = [
  "$A",  # alpha
  "$B",  # beta
]
# kept = "after the block"
CONF
}
run() { CONF="$T/config.toml" KEYS_DIR="$T/keys" "$SA" "$@" >"$T/out" 2>&1; echo $?; }

fixture
check "same set: written"                   0 "$(run alpha beta)"
check "adding a key: written"               0 "$(run alpha beta gamma)"
check "  the new key is in the block"       0 "$(grep -qx "  \"$C\",  # gamma" "$T/config.toml"; echo $?)"
check "  the rest of the file is kept"      0 "$(grep -qx '# kept = "after the block"' "$T/config.toml"; echo $?)"

fixture
check "leaving a key out: refused"          1 "$(run alpha)"
check "  and it names the key it would drop" 0 "$(grep -q 'drop beta' "$T/out"; echo $?)"
check "  and the file is untouched"         0 "$(grep -qx "  \"$B\",  # beta" "$T/config.toml"; echo $?)"
check "--drop beta: written"                0 "$(run --drop beta alpha)"
check "  beta is gone"                      1 "$(grep -q "$B" "$T/config.toml"; echo $?)"
check "listed and dropped: refused"         1 "$(run --drop alpha alpha)"

fixture
sed -i "s/  # beta//" "$T/config.toml"
check "an uncommented key cannot be dropped by name" 1 "$(run --drop beta alpha)"

fixture
check "an avatar with no key file: refused" 1 "$(run alpha beta nobody)"
printf 'not-a-key\n' > "$T/keys/delta/nostr-pubkey-hex"
check "a malformed key file: refused"       1 "$(run alpha beta delta)"
check "no KEYS_DIR: refused"                1 "$(CONF="$T/config.toml" "$SA" alpha >/dev/null 2>&1; echo $?)"

echo; echo "$pass passed, $failn failed"
[ "$failn" = 0 ]

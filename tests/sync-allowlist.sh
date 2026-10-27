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
key beta "$D"
check "a rotated key (same name, new key): written" 0 "$(run alpha beta)"
check "  the new key replaced the old"      0 "$(grep -qx "  \"$D\",  # beta" "$T/config.toml" && ! grep -q "$B" "$T/config.toml"; echo $?)"
key beta "$B"

fixture
sed -i "s/  # beta//" "$T/config.toml"
check "an uncommented key cannot be dropped by name" 1 "$(run --drop beta alpha)"

E=$(printf 'e%063x' 5)
fixture
sed -i "/# beta/a\\  \"$E\",  # external: epsilon -- operator X, source <link>" "$T/config.toml"
check "an external key: written"            0 "$(run alpha beta gamma)"
check "  the external line is kept as it is" 0 "$(grep -qx "  \"$E\",  # external: epsilon -- operator X, source <link>" "$T/config.toml"; echo $?)"
check "  once"                              1 "$(grep -c "$E" "$T/config.toml")"
check "  leaving a fleet key out: still refused" 1 "$(run alpha gamma)"
check "  --drop epsilon does not drop it"   0 "$(run --drop epsilon alpha beta gamma >/dev/null; grep -q "$E" "$T/config.toml"; echo $?)"
sed -i "s/\"$E\"/\"e123\"/" "$T/config.toml"
check "a malformed external key: refused"   1 "$(run alpha beta gamma)"
sed -i "s/\"e123\"/\"$(printf 'E%063X' 5)\"/" "$T/config.toml"
check "an upper-case external key: refused" 1 "$(run alpha beta gamma)"
check "  the line is still there"          0 "$(grep -q '# external: epsilon' "$T/config.toml"; echo $?)"
sed -i "s/\"E[0-9A-F]*\"/\"npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq\"/" "$T/config.toml"
check "an npub external key: refused"      1 "$(run alpha beta gamma)"

fixture
check "an avatar with no key file: refused" 1 "$(run alpha beta nobody)"
printf 'not-a-key\n' > "$T/keys/delta/nostr-pubkey-hex"
check "a malformed key file: refused"       1 "$(run alpha beta delta)"
check "no KEYS_DIR: refused"                1 "$(CONF="$T/config.toml" "$SA" alpha >/dev/null 2>&1; echo $?)"

echo; echo "$pass passed, $failn failed"
[ "$failn" = 0 ]

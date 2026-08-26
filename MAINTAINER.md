# Maintainer runbook — nostr-mailbox provisioning

Agents never mint or hold private keys. The **operator/maintainer** mints one keypair per
avatar, stores the private key in `pass`, and publishes the public parts to
`registry.json`. avatar-builder wires the shared relay + network + injection. This file is
the command block to run **on the host** (not by an agent).

## 1. Mint a keypair per avatar

`nostr-mailbox` ships a script that mints and stores in one step. It needs only **docker
and `pass`** on the host — no Go toolchain, no extra CLI:

```sh
cd <your-path>/applications/tools/nostr-mailbox
scripts/mint-avatar-keys undergryd-software-engineer avatar-builder
```

Per avatar it writes two `pass` entries —

| entry | what |
|---|---|
| `nunet/avatars/<avatar>/nostr-nsec` | the private key (64-char hex; the container also accepts `nsec1…`) |
| `nunet/avatars/<avatar>/mailbox-api-token` | the bearer token between that avatar's `mailbox` CLI and its own container |

— and prints `pubkey_hex` and `npub`, which are what steps 3 and 4 need. **The private key
is never printed**: it goes container stdout → `pass` stdin, so it reaches neither the
screen, scrollback, nor shell history. `PASS_PREFIX` (default `nunet/avatars`) overrides
the store layout.

<details>
<summary>By hand instead, with <code>nak</code></summary>

```sh
# per avatar, e.g. AVATAR=undergryd-software-engineer
nak key generate                 # prints the private key (hex)
SK=<hex-from-above>
nak key public  "$SK"            # pubkey (hex)  -> registry pubkey_hex
nak encode nsec "$SK"            # nsec1...      -> store in pass
nak encode npub "$(nak key public "$SK")"   # npub1... -> registry npub

printf '%s' "$SK" | pass insert -m nunet/avatars/<avatar>/nostr-nsec
```

The secret is on screen this way, so clear the scrollback afterwards.
</details>

`did:key` from the same secp256k1 pubkey (multikey `zQ3s…`, `0x2701` prefix) — derive with
the project's DID tool, or leave `did:key` blank in v1 and fill at nuActor integration.

## 2. Wire the secrets into the avatar's `harness/config`

Two lines in that avatar's `SANDBOX_SECRETS`, so `launch` resolves them from `pass` at
start and exports them — the folded `tools/nostr-mailbox` compose reads them from the same
shell:

```sh
"NOSTR_MAILBOX_NSEC=pass:nunet/avatars/<avatar>/nostr-nsec"
"MAILBOX_API_TOKEN=pass:nunet/avatars/<avatar>/mailbox-api-token"
```

`MAILBOX_API_TOKEN` is **per avatar**, shared between that avatar's sandbox and that
avatar's mailbox container — it is not one fleet-wide value.

## 3. Publish public parts to the shared `registry.json`

Add or update the avatar's entry (`npub`, `pubkey_hex`, `did:key`, `dids`, `display`) —
see `registry.example.json` for the shape. The live file is bind-mounted **read-only** into
every mailbox, at whatever host path that avatar's `MAILBOX_REGISTRY_HOST_PATH` points to.

> Where the live `registry.json` physically lives on the host is **still an open
> decision** — this component ships the format and the example, not the deployed file.

A mailbox **refuses to start** unless its own entry exists and the injected key's derived
pubkey matches that entry (`identity.go`, `loadIdentity`). That is deliberate: a wrong or
swapped key fails loud instead of misdelivering silently.

## 4. Pin the pubkey in the relay allowlist

Add each avatar's `pubkey_hex` to `pubkey_whitelist` in `config.toml`, then restart the
relay (`docker compose restart` in this repo). Closed set = no spam/discovery problem
internally.

## 5. Bring up the shared relay (once)

```sh
cd <your-path>/applications/tools/nostr-relay
docker compose up -d
```

This creates the always-on relay + the shared `nostr-mailbox-net` network that every
avatar's mailbox joins.

## 6. Per-avatar mailbox

The avatar's own `launch` brings up its materialized copy of
`tools/nostr-mailbox/docker-compose.yml` (dual-homed: avatar net + `nostr-mailbox-net`)
with the injected secrets from step 2. The component is project-neutral, so the avatar's
copy is where `MAILBOX_AVATAR` and the three host paths — its `inbox/`, its `outbox/`, and
the shared `registry.json` — get their real values. Install the `mailbox` CLI skill in the
avatar too.

The container runs as the **host user**: its image is built with `MAILBOX_UID`/`MAILBOX_GID`
build args (the harness's `HOST_UID`/`HOST_GID`) so the `inbox/`/`outbox/` binds are
writable and the `/state` volume is not root-owned.

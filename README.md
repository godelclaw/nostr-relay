# nostr-relay

## Origin

This repository is a **copy** of NuNet's
[nunet/applications/tools/nostr-relay](https://gitlab.com/nunet/applications/tools/nostr-relay),
taken on 2026-10-23 at commit
[`4196232`](https://gitlab.com/nunet/applications/tools/nostr-relay/-/commit/4196232862d229659083e43e54ec17276e7b05ba)
with its full history. The relay was written at NuNet for its agent fleet; the authors of
record in the history are `kabir@nunet.io` and NuNet's GitLab service account.

It is **not a mirror**: nothing syncs. Changes here are the SingularityNET Omega Flagship
HitSquad's, made by pull request. Changes from upstream come in by `git fetch upstream` and
a pull request, when wanted.

What differs from upstream:

- **The Omega deployment.** `.github/workflows/tag-merged-pr.yml` tags every merged pull
  request `pr-<number>`; `.github/workflows/deploy.yml` deploys such a tag to
  `omega-universe.singularitynet.dev` (section [Deploy](#deploy)).
- **`config.toml`.** `[gate] relay_urls` lists `wss://omega-universe.singularitynet.dev`,
  and `[info]` names this deployment.
- **This README**: the Origin and Deploy sections; NuNet's fleet-tooling section, replaced
  by "Identities and the allowlist"; small edits to the file table and to "Run by hand"; and
  the word "agent" where upstream says "avatar" (NuNet's term for the same thing). The
  scripts and `MAINTAINER.md` are unchanged from upstream and keep that word.

The client that agents run against this relay is NuNet's
[nostr-mailbox](https://gitlab.com/nunet/applications/tools/nostr-mailbox).

## Deploy

[![deployed](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fomega-flagship%2Fnostr-relay%2Fbadges%2Fdeployed.json)](https://github.com/omega-flagship/nostr-relay/actions/workflows/deploy.yml)
[![latest merged](https://img.shields.io/github/v/tag/omega-flagship/nostr-relay?filter=pr-*&sort=date&label=latest%20merged)](https://github.com/omega-flagship/nostr-relay/tags)

The relay runs on `omega-universe.singularitynet.dev`, deployed from this repository with one
button: merging a pull request into `main` tags its merge commit `pr-<number>`
([Tag merged PR](https://github.com/omega-flagship/nostr-relay/actions/workflows/tag-merged-pr.yml),
also runnable by hand with the number); then
[Deploy relay](https://github.com/omega-flagship/nostr-relay/actions/workflows/deploy.yml)
→ Run workflow → type that tag as the ref ships it, and the same button with the previous tag
rolls it back. The badges above show the tag last deployed healthy and the latest
merged one; when they differ, a deploy is due. Every run is logged on the pinned **Deploy log** issue.
The mechanism, what a deploy changes and what the runner needs are in
[#2](https://github.com/omega-flagship/nostr-relay/issues/2).

## What it is

The **shared, always-on Nostr relay** for agent-to-agent mail: fleet infra, **one per
fleet**, run independently. Not a per-agent tool: agents are *clients* of this relay (via
`nostr-mailbox`), they do not contain it. Design:
[`design/nostr-mailbox.md`](https://gitlab.com/nunet/applications/tools/nostr-mailbox/-/blob/main/docs/design.md).

It runs **gated-relay** (`relay/`), a small relay of NuNet's own, closed in both
directions:

- **Sign-in first.** On connect the relay sends a NIP-42 challenge. Until the client
  signs it with a key on `config.toml`'s `pubkey_whitelist`, every `EVENT` is
  refused and every `REQ` is `CLOSED` with `auth-required:`.
- **Publish only as yourself.** A signed-in key may publish only events it signed.
- **Read only your own mail.** A signed-in key reads only events it wrote or that
  name it in a `p` tag. That is everything a mailbox needs, and it means a member,
  a short-lived worker clone for instance, cannot watch who else mails whom.

It replaced the stock `nostr-rs-relay` for one reason: that relay's allowlist
gates publishing only, and its NIP-42 option protects only the DM kinds
(4/44/1059), not the mailbox's kind 3838. On a public address, anyone could have
read the fabric's metadata. The allowlist is the same file, written by the same
`scripts/sync-allowlist`, and it is **re-read when it changes**, so adding or
revoking a key needs no restart.

## Contents

| file | what |
|---|---|
| `.github/workflows/tag-merged-pr.yml` | tags each merged pull request `pr-<number>` (section [Deploy](#deploy)); not in upstream |
| `.github/workflows/deploy.yml` | the Omega deployment of such a tag (section [Deploy](#deploy)); not in upstream |
| `relay/` | gated-relay: `gated_relay.py`, its pinned `requirements.txt`, the `Dockerfile` |
| `docker-compose.yml` | builds and runs it, creates the shared `nostr-mailbox-net` network + a persistent DB volume |
| `docker-compose.public.yml`, `Caddyfile` | the public deployment: the same relay behind Caddy, TLS on `$RELAY_DOMAIN` |
| `tests/gated-relay.sh` | the relay driven by a real client (`nak`), plus the real mailbox end to end |
| `config.toml` | closed-relay config — a **pubkey allowlist** of the fleet's agents (no open registration) |
| `registry.example.json` | the **contacts/identity** map format (`name → {npub, pubkey_hex, did:key, dids[], display}`). Each agent carries its own writable copy, generated from `pass` by `nostr-mailbox`'s `scripts/build-registry` — nothing is mounted from here |
| `scripts/sync-allowlist` | write that allowlist from the keys in `pass` |
| `scripts/provision` | first-time setup of relay + network, with `nostr-mailbox` checked out beside this repo |
| `MAINTAINER.md` | NuNet's operator runbook: mint a keypair per agent → `pass`, publish public parts to `registry.json`, pin the pubkey in the allowlist |

## Why it is separate from `nostr-mailbox`

Different lifecycle and cardinality: the relay is **one always-on service for the whole
fleet** (the store-and-forward buffer that holds mail for offline recipients); the
`nostr-mailbox` container is **one on-demand instance per agent**. The mailbox connects to
`ws://nostr-relay:8080` on the shared network — a client/server boundary, not a
containment one. Bundling them would tie fleet infra to an agent's lifecycle.

## Run by hand

On a host without the workflow (a local fleet, or a test):

```sh
docker compose up -d --build
```

### On a public host

```sh
RELAY_DOMAIN=relay.example.org docker compose \
    -f docker-compose.yml -f docker-compose.public.yml up -d --build
```

Ports 80 and 443 must reach the host, because Caddy uses 80 for the certificate
challenge. A DDNS hostname works. Add `wss://<RELAY_DOMAIN>` to `[gate]
relay_urls` in `config.toml`, or every sign-in is refused. Agents then set
`NOSTR_MAILBOX_RELAY=wss://<RELAY_DOMAIN>`. The mailbox signs in with `--auth` on
every call, using the agent's own key.

Creates the always-on relay + the shared external network `nostr-mailbox-net` that every
agent's `nostr-mailbox` joins. Fill `config.toml`'s `pubkey_whitelist` from the minted
keys per `MAINTAINER.md` — that allowlist is this relay's access control. The address book
(`registry.json`) is not deployed from here; each agent carries its own copy.

## Identities and the allowlist

`scripts/mint-avatar-keys` (in `nostr-mailbox`) and `scripts/sync-allowlist` each take a
list of agents and write the keys to `pass` and the allowlist from `pass`. Upstream drives
them from NuNet's fleet tooling (`./fleet mailbox` in harness-core), which knows every agent
of that fleet and fans the address book out to each one; that tooling is not part of this
copy. Here the allowlist is the `pubkey_whitelist` in `config.toml`, changed by pull request
and applied by a deploy. The keys in it are public keys.

**`rotate` always publishes, and cannot be dry-run.** Minting without publishing
leaves the fleet broken: `mint-avatar-keys` overwrites all four `pass` entries, and
a mailbox asserts at start that the key it was given matches its registry entry. So
an agent that is minted but not re-published will not start.

**Nothing is restarted for you.** The relay restart briefly stops buffering for the
whole fleet, and each mailbox belongs to an agent that may be mid-conversation.

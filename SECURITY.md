# Security policy

## Reporting a vulnerability

**Please do not open a public issue.**

Report privately through GitHub: **[Security → Report a vulnerability][advisory]** on this
repository. That creates a private advisory only the maintainers can see, and it is the
preferred route — it needs no email address and gives us a place to coordinate a fix and a
disclosure with you.

[advisory]: https://github.com/jparadasb/hydra-ai/security/advisories/new

What helps, in rough order of usefulness:

- what an attacker gets, concretely
- the smallest reproduction you have
- affected version — `hydra-worker --version`, or the coordinator image tag
- whether it is already public anywhere

Expect an acknowledgement within a few days. This is a small project; there is no bounty, and
no SLA beyond a good-faith effort to fix things that matter quickly.

## Supported versions

Only the latest release gets fixes. There are no maintenance branches.

| | |
|---|---|
| Worker | the most recent `v*` release |
| Coordinator | the image built from `main` |

The desktop app and the headless CLI both auto-update, so "upgrade" is usually the remedy:
`hydra-worker update --restart`, or the in-app banner.

## What this project handles

Worth knowing when judging whether something is a vulnerability here:

- **Provider API keys live on the worker and never transit the coordinator.** This is the
  central claim. `Secret` is non-serializable on the worker, and `Coordinator.SecretGuard`
  redacts secret-shaped values at the coordinator boundary as defense in depth. Anything that
  gets a provider token to the coordinator, into its database, or into its logs is a
  vulnerability in this project's core rule — report it.
- **Gateway keys** authorize callers of the OpenAI-compatible front door. Only SHA-256 hashes
  are stored; the plaintext is shown once. A leaked key is revoked from `/admin`.
- **Worker device keys** are Ed25519, pinned trust-on-first-use, private half never leaving the
  worker.
- **Desktop updates** are signed with a minisign key and verified by the installed app. A way
  to get an unsigned or attacker-signed update accepted is a serious finding.
- **Job text.** A job row holds the caller's prompt and the worker's completion; both are
  redacted after a configurable window and the row is deleted after a longer one. See the
  README's "Core rule" section for what is and is not kept.

### Out of scope

- Missing Apple notarization / Windows Authenticode signatures. Known, documented in
  `docs/updater-key-rotation.md`, and not yet configured.
- An intentionally open deployment. Worker auth and the gateway-key requirement can be turned
  off; `.env.example` ships with them on, and running without them is a choice.
- Findings that require an attacker who already controls the coordinator host or a worker host.

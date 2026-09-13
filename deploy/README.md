# Deployment

This directory used to be empty, which read as "there is no deployment" rather than "the
manifests live elsewhere".

## Where the manifests are

The production Kubernetes manifests are in a separate GitOps repository:

| | |
|---|---|
| Repo | `jparadasb/lambdatauri-cluster-fleet` |
| Path | `clusters/tauri/apps/hydra/deployment.yaml` |
| Reconciled by | Flux |

`.github/workflows/coordinator.yml` builds the coordinator image, pushes it to OCIR tagged with
the commit SHA, then commits the new tag into that file. Flux rolls it out. Nothing in this
repository is applied to the cluster directly.

## What that deployment needs from here

The image is `coordinator/Dockerfile`. It runs as a non-root user, exposes 4000, and has a
`HEALTHCHECK` against `/health` — the manifest should have matching readiness and liveness
probes:

```yaml
readinessProbe:
  httpGet: { path: /health, port: 4000 }
  initialDelaySeconds: 10
  periodSeconds: 10
livenessProbe:
  httpGet: { path: /health, port: 4000 }
  initialDelaySeconds: 30
  periodSeconds: 30
```

Configuration is entirely environment variables; `.env.example` at the repo root is the
reference, and every variable in it applies equally to a k8s Secret/ConfigMap. The ones that
are not optional in a clustered deployment:

- `DB_ADAPTER=postgres` — required explicitly, no default, and it must match the image's build.
  A SQLite file cannot back more than one replica and the coordinator refuses to start
  clustered on it.
- `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`
- `HYDRA_CLUSTER_SERVICE` plus `RELEASE_DISTRIBUTION=name`, `RELEASE_NODE=<name>@<pod-ip>` and
  a shared `RELEASE_COOKIE`, for Presence and PubSub to span replicas.

`/metrics` is served on the same port. It is an operational surface — the ingress should not
route it publicly.

## Local and single-host deployment

`docker-compose.yml` at the repo root: Postgres, the coordinator, a nightly `pg_dump` sidecar,
and a Cloudflare tunnel. `cp .env.example .env`, fill the three required secrets, then
`docker compose up -d --build`.

Backups land in `./backups`. Restoring them — and everything else that goes wrong — is
[`docs/runbook.md`](../docs/runbook.md).

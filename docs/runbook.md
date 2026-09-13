# Runbook

What to do when something is wrong. Each procedure assumes the compose stack in this
repository; the Kubernetes deployment is described in [`deploy/README.md`](../deploy/README.md).

Read [Restore the database](#restore-the-database) before you need it. A backup whose restore
has never been run is a guess.

---

## Restore the database

Backups are written nightly by the `pg-backup` service to `./backups/hydra-<timestamp>.sql.gz`
and kept for `BACKUP_RETENTION_DAYS` (default 14).

```sh
ls -lh backups/                       # newest last
```

Restoring is destructive — it drops the current contents. Stop writers first so the coordinator
cannot insert a job into a half-restored database:

```sh
docker compose stop coordinator

# Keep a dump of the current state before overwriting it, even if it is broken. It is the only
# thing standing between a bad restore and having nothing at all.
docker compose exec -T postgres pg_dump -U hydra hydra | gzip > backups/pre-restore-$(date -u +%Y%m%dT%H%M%SZ).sql.gz

gunzip -c backups/hydra-<timestamp>.sql.gz \
  | docker compose exec -T postgres psql -U hydra -d hydra -v ON_ERROR_STOP=1

docker compose start coordinator
docker compose logs -f coordinator      # migrations run on boot; watch for errors
```

Then check it actually came back: `/health` returns ok, `/admin/dashboard` shows the expected
job counts, and a worker reconnects.

**Verify this works before you need it.** Restore into a scratch database and compare row
counts:

```sh
docker compose exec -T postgres createdb -U hydra hydra_restore_test
gunzip -c backups/<newest>.sql.gz | docker compose exec -T postgres psql -U hydra -d hydra_restore_test -v ON_ERROR_STOP=1
docker compose exec -T postgres psql -U hydra -d hydra_restore_test -c 'select count(*) from jobs;'
docker compose exec -T postgres dropdb -U hydra hydra_restore_test
```

## Roll back the coordinator

Images are tagged by commit SHA. The GitOps repo
(`jparadasb/lambdatauri-cluster-fleet`, `clusters/tauri/apps/hydra/deployment.yaml`) holds the
tag that is deployed.

1. Find the previous good SHA: `gh release list`, or the deployment file's git history.
2. Edit the image tag in the fleet repo and push. Flux rolls it out.
3. Watch: `kubectl -n hydra rollout status deploy/hydra-coordinator`.

**Migrations do not roll back with the image.** Check whether the bad release added one
(`coordinator/priv/repo/migrations/`). If it did and the old code cannot run against the new
schema, roll the migration back explicitly *before* deploying the old image:

```sh
bin/coordinator eval 'Coordinator.Release.rollback(Coordinator.Repo, <previous_version>)'
```

Compose equivalent: change the image or rebuild from the previous commit, then
`docker compose up -d coordinator`.

## Rotate `SECRET_KEY_BASE`

It signs the admin session cookie. Rotating it logs every admin out; it does **not** affect
gateway keys, worker device keys, or job data.

```sh
openssl rand -base64 48           # or: mix phx.gen.secret
```

Put it in `.env` (or the k8s secret), then restart the coordinator. Admins log in again through
GitHub OAuth. If you are rotating because it leaked, also review `/admin` for API keys you do
not recognize.

## A gateway key leaked

Gateway keys are stored only as SHA-256 hashes, so the key itself cannot be read back out of
the database — but a leaked plaintext is usable until revoked.

1. Revoke it in `/admin`. Revocation takes effect on the next request; there is no cache.
2. Find what it did: usage rows are attributed to the key id.
   ```sh
   docker compose exec -T postgres psql -U hydra -d hydra -c \
     "select date_trunc('hour', inserted_at) h, count(*), sum(total_tokens)
        from usage_records where api_token_id = '<tok-id>' group by 1 order by 1 desc limit 24;"
   ```
3. Issue a replacement and update whatever was using the old one.
4. If it was the env master key (`HYDRA_API_TOKEN`) rather than an admin-issued one, there is
   no revocation: change the variable and restart. That invalidates it for every caller at
   once, so have the replacement ready first.

## Drain a worker

Workers hold leases. Killing one strands its in-flight jobs until their leases expire (up to
the lease timeout), at which point the coordinator reclaims and re-queues them.

To drain gracefully, stop the worker from taking new work and let the current jobs finish:

```sh
# On the worker host. Stop the service; the coordinator reclaims anything still leased.
systemctl stop hydra-worker
```

Then confirm from the coordinator side that its leases came back: `/admin/dashboard`, or watch
for `lease reclaimed and job requeued` in the logs. A worker that disconnects cleanly has its
leases reclaimed immediately by its channel's `terminate`; a worker that vanishes waits for the
lease deadline.

To stop routing to a worker without stopping it, revoke its device key in `/admin/workers` —
it is rejected on its next reconnect.

## The updater signing key is lost or leaked

See [`updater-key-rotation.md`](updater-key-rotation.md). Short version: rotation takes **two**
releases, because an installed desktop app only trusts the key it shipped with. If the key is
lost outright there is no recovery — users must download and install manually.

## A worker looks wedged

Symptoms: jobs leased to it never complete, and they fail after their lease expires.

1. Check it is actually connected: `/admin/workers`, or the `hydra_workers_connected` metric.
2. Look for reclaims: `hydra_lease_reclaimed_count{outcome="failed"}` rising is the signal, and
   the coordinator logs `job failed after lease expiry` with the worker id.
3. On the worker host: `journalctl -u hydra-worker -f`. Run it with `HYDRA_LOG=debug` and
   `HYDRA_LOG_FORMAT=json` if the default level is not enough.
4. Revoke the device key if it is misbehaving rather than merely slow — that stops new work
   reaching it without needing access to the host.

## Useful signals

| Question | Where |
|---|---|
| Is it up? | `GET /health` |
| Is anything failing? | `hydra_job_completed_count{status="failed"}`, `hydra_lease_reclaimed_count` |
| Is someone hammering it? | `hydra_api_rate_limited_count`, `hydra_api_auth_rejected_count` |
| Are workers connected? | `hydra_workers_connected` |
| Is a worker slow? | `hydra_job_duration_millisecond` |
| What did this job do? | coordinator logs, filtered on `job_id` |

# Deploying Plunk to Cloud Run

Plunk deploys as three Cloud Run workloads built from `Dockerfile` + `Dockerfile.services`:

| Workload | Cloud Run surface | Image          | Why                                                              |
| -------- | ----------------- | -------------- | ---------------------------------------------------------------- |
| `api`    | Service           | `plunk-api`    | Serves HTTP, and runs the workflow/domain-verification cron jobs. |
| `worker` | **Worker pool**   | `plunk-worker` | Consumes BullMQ queues. Serves no requests.                       |
| `web`    | Service           | `plunk-web`    | The Next.js dashboard.                                            |

Everything is driven by `cloudbuild.yaml`. You never build or push images locally.

```bash
yarn deploy
```

That uploads the working tree to Cloud Build, which builds all three images, pushes them to
Artifact Registry tagged with the commit SHA, runs the migration Cloud Run Job, and rolls out
the three workloads.

## One-time setup

```bash
cp deploy/config.example.env deploy/config.env
$EDITOR deploy/config.env          # project, region, resource names, secret refs
yarn deploy:setup                  # APIs, Artifact Registry, service accounts, secrets
```

`yarn deploy:setup` is idempotent — re-run it after changing `deploy/config.env`. It prints the
`gcloud secrets versions add` command for every secret that still has no value; instances crash on
startup until those are filled, because `apps/api/src/app/constants.ts` throws on any missing
required variable.

Then review `deploy/env/{api,worker,web}.yaml` and set the four `*_URI` values to your real
hostnames.

## Everyday use

```bash
yarn deploy                     # all three, with migrations
yarn deploy --only web          # just the dashboard
yarn deploy --only api,worker   # backend only
yarn deploy --no-migrate        # skip the migration job
yarn deploy --migrate-only      # run migrations, deploy nothing
yarn deploy --dry-run           # print the gcloud invocation, change nothing
```

The build source is your **working tree**, not `HEAD`. Uncommitted changes are deployed — usually
what you want from a deploy command, but such builds are tagged `<sha>-dirty` so you can tell from
the image tag that the running code is not in git.

## Configuration model

Three places, with a deliberate split:

- **`deploy/config.env`** (gitignored) — names GCP resources. No values, only identifiers and
  Secret Manager references.
- **`deploy/env/*.yaml`** (committed) — the literal, non-secret environment for each workload.
  Applied with `--env-vars-file`, which **replaces** the workload's full env on every deploy. That
  is the point: this file is the source of truth, so a value someone edits in the console does not
  survive the next deploy.
- **Secret Manager** — everything credential-shaped, injected by reference via `--set-secrets`. The
  values never pass through Cloud Build.

`worker.yaml` repeats the `*_URI` values from `api.yaml` because the worker imports the same
`constants.ts` and renders emails containing dashboard links. Keep them in sync.

## Two things that fail silently

**CORS.** The API's `DASHBOARD_URI` is its CORS allowlist entry. If it is not byte-identical to the
origin the browser loads the dashboard from, every authenticated request is rejected and the
dashboard looks broken rather than misconfigured.

**Cookie domain.** The API derives the auth cookie's `Domain` from the last two labels of
`API_URI`'s hostname. On default Cloud Run hostnames (`https://plunk-api-abc123-ew.a.run.app`) that
produces `Domain=.run.app` — and because `run.app` is on the Public Suffix List, browsers silently
drop the cookie. Login appears to succeed and the dashboard immediately behaves as logged out.

Custom domains are therefore effectively required:

```bash
gcloud beta run domain-mappings create --service=plunk-web --domain=app.example.com --region="$REGION"
gcloud beta run domain-mappings create --service=plunk-api --domain=api.example.com --region="$REGION"
```

Then set `API_URI=https://api.example.com` and `DASHBOARD_URI=https://app.example.com` in **all**
of `deploy/env/*.yaml` — the shared `.example.com` cookie domain is what makes the session work
across the two services.

## Why the worker is a pool, not a service

A Cloud Run *service* must bind `$PORT` or the revision is killed as "failed to start and listen",
and its CPU is throttled between requests. The worker serves no requests — it consumes Redis
queues — so as a service it would need a fake HTTP server and `--no-cpu-throttling` to behave.

A worker pool is the surface built for this: no port, no ingress, no traffic split, and CPU always
allocated. Scaling is manual via `--instances`, which also gives you a clean kill switch:

```bash
gcloud run worker-pools update plunk-worker --region="$REGION" --instances=0   # pause queue processing
```

The worker still exposes `GET /health` on `WORKER_HEALTH_PORT` (default 8081). It reports `200` only
when the queue connections are actually `ready` — a worker whose Redis is unreachable answers `503
{"status":"disconnected"}` rather than claiming to be healthy, which is what makes it usable as a
liveness probe.

## Migrations

`deploy/config.env`'s `MIGRATE_JOB` names an existing Cloud Run Job. Each deploy repoints it at the
new `plunk-api` image and executes it with `--wait` **before** any workload is rolled out, so new
code never meets an old schema. A failed migration fails the build and nothing is deployed.

Set `MIGRATE_JOB=` to take migrations out of the pipeline entirely.

## Rollback

Services roll back by traffic; the worker pool rolls back by image.

```bash
gcloud run revisions list --service=plunk-api --region="$REGION"
gcloud run services update-traffic plunk-api --region="$REGION" --to-revisions=plunk-api-00042-abc=100

gcloud run worker-pools update plunk-worker --region="$REGION" \
  --image="${REGION}-docker.pkg.dev/${PROJECT_ID}/plunk/plunk-worker:<previous-tag>"
```

Because every image is tagged with its commit SHA, `<previous-tag>` is just the previous commit.

## Build performance

Cloud Build starts on a clean VM, so the pipeline pushes three cache images (`plunk-deps`,
`plunk-prod-deps`, `plunk-builder`) tagged `:cache` and restores them with `--cache-from` on the
next run. They are cached separately on purpose — inline cache only carries the layers of the stage
being tagged, so caching `builder` alone would still re-run `yarn install` every time.

A cold build compiles the whole monorepo and takes a while; a warm build with unchanged
dependencies is substantially shorter. The `builder` stage still compiles all five apps (including
`smtp`, `landing` and `wiki`, which produce no image here) — layer caching keeps that cheap when
those apps have not changed.

Note that `--platform linux/amd64` is no longer your problem: Cloud Build workers are amd64, so
there is no cross-architecture build to forget about on an Apple Silicon machine.

## Automatic deploys

`yarn deploy:trigger` wires a Cloud Build GitHub trigger that runs this same `cloudbuild.yaml` on
push. See [ci-cd-github.md](./ci-cd-github.md) for how that compares with the deploy-key workflow it
replaces.

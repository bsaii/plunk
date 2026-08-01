# Building and deploying api + web + worker with Cloud Build

`cloudbuild.yaml` (repo root) builds the `api`, `web` and `worker` images from
`Dockerfile.services`, pushes them to Artifact Registry, updates the `plunk-api` and `plunk-web`
Cloud Run services, keeps the `plunk-migrate` Cloud Run Job pointed at the same api image, and
updates the `plunk-worker` Cloud Run Worker Pool — all on Google's build infrastructure. Use this
instead of running `docker build` in Cloud Shell: the monorepo build (installing dependencies and
compiling every app) is big enough to fill Cloud Shell's small local disk, and Cloud Build doesn't
have that limit.

`landing` and `wiki` aren't wired up yet — they're still only built as part of the all-in-one
image (`Dockerfile`). Adding them later is the same shape: another `build` → `push` → `deploy`
step chain in the same file.

**BuildKit**: the root `Dockerfile` uses `--mount=type=cache` (a BuildKit-only feature) to cache
the yarn/turbo/npm installs between builds. The `gcr.io/cloud-builders/docker` image Cloud Build
runs doesn't turn BuildKit on by default, so every `docker build` step in `cloudbuild.yaml` sets
`env: ["DOCKER_BUILDKIT=1"]` — without it, the build fails on the first cache-mounted line.

**Why the worker is a Worker Pool, not a Cloud Run service**: `apps/api/src/jobs/worker.js` is a
pure background process — it never listens on an HTTP port. A regular Cloud Run service requires
the container to bind `$PORT` and pass a startup health check, so this exact image would fail to
deploy as one. Cloud Run Worker Pools are the resource built for this: continuously-running
background workloads with no HTTP requirement. Worker Pools are a newer part of Cloud Run —
before relying on the `update-worker-pool` step, confirm the command exists for you:
`gcloud run worker-pools --help`. If gcloud doesn't recognize it, run
`gcloud components install beta` and use `gcloud beta run worker-pools ...` instead (adjust the
`update-worker-pool` step in `cloudbuild.yaml` to match).

## Before your first run: check what you already have

If you've clicked through the console at all, check for existing resources before running
anything below — this file only ever *builds, pushes and updates*. It never creates an Artifact
Registry repo or a Cloud Run service, specifically so it can't create a second one next to
something you already made with a different name.

```bash
# Do you already have an Artifact Registry repo? What's it called, what region?
gcloud artifacts repositories list

# Do you already have Cloud Run services? What are they named?
gcloud run services list --region=YOUR_REGION

# Do you already have the plunk-migrate Cloud Run Job?
gcloud run jobs list --region=YOUR_REGION

# Do you already have a plunk-worker Cloud Run Worker Pool?
gcloud run worker-pools list --region=YOUR_REGION
```

Then open `cloudbuild.yaml` and edit the `substitutions` block at the top so `_REGION`,
`_AR_REPO`, `_API_SERVICE`, `_WEB_SERVICE`, `_MIGRATE_JOB` and `_WORKER_POOL` match what you
found — or leave the file alone and pass them on the command line instead (shown below),
whichever is easier to keep straight.

## One-time setup

Skip anything you already found above.

```bash
# 1. Artifact Registry repo (only if `gcloud artifacts repositories list` came back empty)
gcloud artifacts repositories create plunk \
  --repository-format=docker \
  --location=us-central1 \
  --description="Plunk service images"

# 2. Let this Cloud Build pipeline push to it and deploy to Cloud Run.
#    Cloud Build runs as a Google-managed service account named after your
#    project number — find the number, then grant it the three roles it needs.
#    roles/run.admin covers Cloud Run services (plunk-api, plunk-web), Cloud
#    Run Jobs (plunk-migrate), and — as far as we've verified — Worker Pools
#    (plunk-worker) too, since they're all under the same run.googleapis.com
#    API. If update-worker-pool fails with a permissions error even after
#    granting this, it may need its own IAM permission as a newer resource
#    type — check the error message for the specific permission it wants.
PROJECT_NUMBER=$(gcloud projects describe "$(gcloud config get-value project)" --format='value(projectNumber)')
CB_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"

gcloud projects add-iam-policy-binding "$(gcloud config get-value project)" \
  --member="serviceAccount:${CB_SA}" --role="roles/artifactregistry.writer"

gcloud projects add-iam-policy-binding "$(gcloud config get-value project)" \
  --member="serviceAccount:${CB_SA}" --role="roles/run.admin"

gcloud projects add-iam-policy-binding "$(gcloud config get-value project)" \
  --member="serviceAccount:${CB_SA}" --role="roles/iam.serviceAccountUser"
```

```bash
# 3. The Cloud Run services themselves. `gcloud run deploy --image=...` (what
#    cloudbuild.yaml runs) is normally create-or-update, but a `check-*-exists`
#    step now runs before each deploy step and fails the build if the service
#    is missing — specifically so a build can never silently create a
#    mis-configured plunk-api/plunk-web from scratch. If they don't exist
#    yet, create them once, by hand, from Cloud Shell — order matters a bit
#    since each needs the other's URL:

# API first — same shape as web below, with the API's own env vars
# (DATABASE_URL, REDIS_URL, JWT_SECRET, S3_*, AWS_SES_*, etc. — see
# apps/api/.env.example). DASHBOARD_URI isn't known yet at this point, so
# leave it pointing at localhost for now — you'll circle back and fix it
# once plunk-web exists too, same two-step dance as below.
gcloud run deploy plunk-api \
  --image="us-central1-docker.pkg.dev/$(gcloud config get-value project)/plunk/api:bootstrap" \
  --region=us-central1 \
  --platform=managed \
  --allow-unauthenticated \
  --port=8080 \
  --set-env-vars="DATABASE_URL=...,DIRECT_DATABASE_URL=...,REDIS_URL=...,JWT_SECRET=...,DASHBOARD_URI=http://localhost:3000"

API_URI=$(gcloud run services describe plunk-api --region=us-central1 --format='value(status.url)')
echo "plunk-api is at: $API_URI"

# Web dashboard next — needs the real plunk-api URL for API_URI. Its own URL
# (DASHBOARD_URI) still isn't known until after this first deploy, so the
# same two-step dance as docs/deploy-cloud-run.md applies: deploy once, read
# the URL back, then patch DASHBOARD_URI on both services.
gcloud run deploy plunk-web \
  --image="us-central1-docker.pkg.dev/$(gcloud config get-value project)/plunk/web:bootstrap" \
  --region=us-central1 \
  --platform=managed \
  --allow-unauthenticated \
  --port=8080 \
  --cpu=1 \
  --memory=512Mi \
  --min-instances=0 \
  --max-instances=10 \
  --set-env-vars="API_URI=${API_URI},LANDING_URI=https://www.example.com,WIKI_URI=https://docs.example.com"

DASHBOARD_URI=$(gcloud run services describe plunk-web --region=us-central1 --format='value(status.url)')
echo "plunk-web is at: $DASHBOARD_URI"

# Now that DASHBOARD_URI is known, patch it onto BOTH services — the API
# needs it for CORS + the auth cookie domain, matching docs/deploy-cloud-run.md.
gcloud run services update plunk-api --region=us-central1 --update-env-vars="DASHBOARD_URI=${DASHBOARD_URI}"
gcloud run services update plunk-web --region=us-central1 --update-env-vars="DASHBOARD_URI=${DASHBOARD_URI}"
# (the --image flags above are placeholder tags just to satisfy the first
#  deploy — the very next Cloud Build run replaces both with real
#  commit-tagged images. See docs/deploy-cloud-run.md for the custom-domain
#  / auth-cookie requirements you'll want before using this for real users —
#  default *.run.app URLs silently break login, as that doc explains.)

# plunk-migrate (the Cloud Run Job that runs `prisma migrate deploy` off the
# api image) is assumed to already exist — cloudbuild.yaml only ever updates
# its image, it never creates the job. If it doesn't exist yet:
gcloud run jobs create plunk-migrate \
  --image="us-central1-docker.pkg.dev/$(gcloud config get-value project)/plunk/api:bootstrap" \
  --region=us-central1 \
  --command="node_modules/.bin/prisma" \
  --args="migrate,deploy,--schema=packages/db/prisma/schema.prisma" \
  --set-env-vars="DATABASE_URL=...,DIRECT_DATABASE_URL=..."

# plunk-worker (the Worker Pool running the BullMQ queue consumers) doesn't
# exist yet — create it once, by hand. Its env vars are a SUBSET of the API's
# (S3_*, OAuth, Stripe price IDs, etc. are HTTP-only and not needed here) —
# see the "Worker environment variables" section below for exactly which ones
# and why. Check `gcloud run worker-pools create --help` for the current flag
# set (this is a newer resource type, so scaling/CPU flags may differ from
# what's shown here) before running this for real:
gcloud run worker-pools create plunk-worker \
  --image="us-central1-docker.pkg.dev/$(gcloud config get-value project)/plunk/worker:bootstrap" \
  --region=us-central1 \
  --set-env-vars="NODE_ENV=production,DATABASE_URL=...,DIRECT_DATABASE_URL=...,REDIS_URL=...,AWS_SES_REGION=...,AWS_SES_ACCESS_KEY_ID=...,AWS_SES_SECRET_ACCESS_KEY=...,DASHBOARD_URI=...,LANDING_URI=...,API_URI=...,WIKI_URI=...,JWT_SECRET=..."
# (again, the --image above is just a placeholder to satisfy creation — the
#  next Cloud Build run replaces it with a real commit-tagged image)
```

### Worker environment variables

Traced from `apps/api/src/jobs/worker.ts`'s actual import graph (verified by running the compiled
worker against a real local Postgres + Redis — see PR discussion). The worker's `app/constants.ts`
validates several vars at import time regardless of which queue ever runs a job, so a few of these
are "required to boot" without being functionally used by any processor.

**Required — actually used by worker logic:**

| Variable | Why |
| --- | --- |
| `REDIS_URL` | BullMQ connection (every queue) |
| `DATABASE_URL` | Prisma — every processor queries the DB |
| `AWS_SES_REGION`, `AWS_SES_ACCESS_KEY_ID`, `AWS_SES_SECRET_ACCESS_KEY` | Sending email (email-processor), rate-limit lookup |
| `DASHBOARD_URI` | Unsubscribe/manage links baked into sent emails |
| `LANDING_URI` | Used in notification email templates (domain verification, billing limit) |

**Required to boot, but not otherwise used by the worker** (set to a real value anyway — cheap
insurance against a future code path needing it, and `API_URI` becomes a real dependency the
moment `PLUNK_API_KEY` is set):

| Variable | Note |
| --- | --- |
| `DIRECT_DATABASE_URL` | Set the same as `DATABASE_URL` — only the Prisma schema's `directUrl` (migrations) cares about the distinction, and the worker never migrates |
| `JWT_SECRET` | Only read by HTTP auth middleware; use the same value as `plunk-api` |
| `API_URI` | Unused unless `PLUNK_API_KEY` is set, in which case platform notification emails call it |
| `WIKI_URI` | Never referenced by worker logic at all |

**Optional — only if you use the feature:**

`SES_CONFIGURATION_SET` / `SES_CONFIGURATION_SET_NO_TRACKING` (default to the standard names),
`EMAIL_RATE_LIMIT_PER_SECOND` / `EMAIL_WORKER_CONCURRENCY` / `EMAIL_WORKER_MAX_CONCURRENCY`
(tuning), `STRIPE_SK` / `STRIPE_WEBHOOK_SECRET` / `STRIPE_METER_EVENT_NAME` (billing),
`PLUNK_API_KEY` / `PLUNK_FROM_ADDRESS` (platform notification emails), `NTFY_URL` (ops
notifications), `OPENROUTER_API_KEY` / `OPENROUTER_MODEL` / `PHISHING_*` (phishing detection).
`NODE_ENV=production` is worth setting explicitly too.

**Not needed at all** (confirmed unreachable from the worker's code path — these are HTTP-only):
`S3_*` (uploads go through the API service, not the worker), `GITHUB_OAUTH_*` / `GOOGLE_OAUTH_*`,
`STRIPE_PRICE_ONBOARDING` / `STRIPE_PRICE_EMAIL_USAGE` (checkout), `AUTO_PROJECT_DISABLE` (SNS
webhook handler), `SMTP_*` / `PORT_SECURE` / `PORT_SUBMISSION`, `PORT` (the worker never listens
on one), `DISABLE_SIGNUPS`, `VERIFY_EMAIL_ON_SIGNUP`.

## Running it

From the repo root, on the branch/commit you want to ship:

```bash
gcloud builds submit \
  --config=cloudbuild.yaml \
  --substitutions=_TAG=$(git rev-parse --short HEAD)
```

That single command builds all three images tagged with the current commit's short SHA, pushes
them to Artifact Registry, rolls `plunk-api` and `plunk-web` over to the new images, updates
`plunk-worker` to the new worker image, and points `plunk-migrate` at the same new api image —
nothing else about any of their configuration (env vars, secrets, scaling settings) is touched,
and the migrate job is only *updated*, never executed automatically.

If this build introduced new migrations, run them yourself once you're ready (this is a
deliberate manual step, not part of the pipeline):

```bash
gcloud run jobs execute plunk-migrate --region=us-central1 --wait
```

Override any of the location substitutions the same way, if you didn't edit the defaults in
the file:

```bash
gcloud builds submit --config=cloudbuild.yaml \
  --substitutions=_TAG=$(git rev-parse --short HEAD),_REGION=europe-west1,_AR_REPO=plunk,_API_SERVICE=plunk-api,_WEB_SERVICE=plunk-web
```

## Continuous deployment: wiring GitHub to Cloud Build

Everything above is you manually running `gcloud builds submit`. To have Cloud Build build and
deploy automatically whenever you merge, you need a **Cloud Build Trigger** watching the GitHub
repo — no GitHub Actions required. Cloud Build has native GitHub integration and just runs this
same `cloudbuild.yaml`; there's no second CI config to keep in sync.

**Why not GitHub Actions:** you could wire this to a GitHub Actions workflow instead (one that
shells out to `gcloud builds submit`, or runs `docker build`/`push`/`gcloud run deploy` directly
on a GitHub-hosted runner), but that means setting up a GCP service account key or Workload
Identity Federation just so GitHub can authenticate to your project, and the build would run on
GitHub's runners instead of Cloud Build's — weaker disk/CPU, and you'd lose the shared
`builder`/`prod-deps` layer caching this file already gets from running on the same Cloud Build
worker pool every time. Since you're already all-in on Cloud Build/Artifact Registry/Cloud Run, a
native trigger is strictly less to maintain.

### One-time: connect the repo

Cloud Build genuinely has no idea `bsaii/plunk` exists yet. Connecting it means authorizing a
GitHub App, which is an interactive browser step no CLI command avoids. **Do this one through the
console**: Cloud Build → Triggers → Connect Repository → GitHub → authorize the app on
`bsaii/plunk`. The guided flow handles the OAuth/App-install dance and is the more foolproof path
for a first connection. Everything after (creating/editing triggers) can be done via gcloud or
console from then on.

### Create the trigger

Console: Cloud Build → Triggers → Create Trigger → pick the connected `plunk` repo → event "Push
to a branch" → branch pattern `^production$` → configuration "Cloud Build configuration file" →
path `cloudbuild.yaml`. Set the `_TAG` substitution to `$SHORT_SHA` — a built-in variable Cloud
Build fills in automatically for trigger-fired builds, the same commit-SHA tagging every manual
run above uses, just no longer something you type.

Equivalent gcloud (double-check the exact flags with `gcloud builds triggers create github --help`
first — this API's shape has changed a couple of times, so treat this as a starting point):

```bash
gcloud builds triggers create github \
  --name=plunk-deploy-on-merge \
  --region=us-central1 \
  --repository=projects/$(gcloud config get-value project)/locations/us-central1/connections/<your-connection-name>/repositories/<your-repo-name> \
  --branch-pattern="^production$" \
  --build-config=cloudbuild.yaml \
  --substitutions=_TAG='$SHORT_SHA'
```

No `--require-approval` flag — every merge deploys immediately, no manual gate. (If you want one
later: add `--require-approval` and the trigger queues each build pending a click in
Console → Cloud Build → History before it actually runs.)

### What happens when you merge

1. You merge a PR into `production` on GitHub.
2. GitHub sends Cloud Build a webhook; the trigger's branch pattern matches, so it queues a build.
3. Cloud Build clones the repo at that merge commit, resolves `$SHORT_SHA` to the real commit
   hash, and runs `cloudbuild.yaml` exactly like a manual `gcloud builds submit` — same steps,
   same service account, same IAM.
4. It builds all three images tagged with that commit, pushes them to Artifact Registry, rolls
   `plunk-api` and `plunk-web` over to the new images, updates `plunk-worker`, and updates (never
   executes) `plunk-migrate`'s image.
5. You watch it in Console → Cloud Build → History, same as any manual run.

One real nuance: steps aren't transactional across the whole build. If `build-web` fails,
`plunk-api` may already have rolled to the new commit while `plunk-web` stays on the old one —
"the build failed" doesn't always mean "nothing changed."

### Cloud Build basics, briefly

- **Triggers** (Console: Cloud Build → Triggers) — the thing watching a repo that decides when to
  fire a build. Yours shows up here once created; pause, edit, or manually re-run it from this
  screen any time.
- **History** (Console: Cloud Build → History) — every build, past and in-progress, with per-step
  logs (`gcloud builds log --stream BUILD_ID` is the CLI equivalent), duration, and the resolved
  substitution values that build actually ran with.
- **Service account** — the same `PROJECT_NUMBER@cloudbuild.gserviceaccount.com` already granted
  `artifactregistry.writer`/`run.admin`/`iam.serviceAccountUser` in the one-time setup above.
  Manual and trigger-fired builds both run as this identity — nothing new to grant.
- **Where the images land** — Artifact Registry → your `plunk` repo, browsable per-image with
  every tag/digest.
- **Cost** — Cloud Build has a daily free-tier build-minute allowance, then bills per build-minute
  by machine type; `E2_HIGHCPU_8` (what `cloudbuild.yaml` requests) costs more per minute than the
  default but finishes this particular build faster.

## Watching a run / troubleshooting

```bash
# Stream logs for the build you just submitted (gcloud builds submit does this
# automatically unless you passed --async).
gcloud builds log --stream BUILD_ID

# List recent builds and their status.
gcloud builds list --limit=5
```

If `check-api-exists` or `check-web-exists` fails ("NOT_FOUND" / non-zero exit), the service
hasn't been created yet — do the one-time bootstrap deploy in step 3 above first. These two steps
don't `waitFor` anything, so they run immediately and fail within seconds rather than after the
whole (slow) build — you don't have to wait 15+ minutes to find out you skipped a step.

If `deploy-api`, `deploy-web`, `update-migrate-job` or `update-worker-pool` fails with a
permissions error, re-check step 2 of the one-time setup above — that's almost always a missing
IAM role on the Cloud Build service account. If a `docker build` step fails complaining about
`--mount` or BuildKit, check that step still has `env: ["DOCKER_BUILDKIT=1"]` set (see the
BuildKit note above). If `update-worker-pool` fails with something like "Invalid choice:
'worker-pools'", your gcloud CLI needs the beta component — see the Worker Pool note above.

If the build fails immediately (before any step even starts) with "if 'build.service_account' is
specified, the build must either (a) specify 'build.logs_bucket', (b) use the
REGIONAL_USER_OWNED_BUCKET ... option, or (c) use ... CLOUD_LOGGING_ONLY / NONE logging options" —
your project assigns builds a non-default service account, and Cloud Build won't guess where logs
go. `cloudbuild.yaml`'s `options.logging: CLOUD_LOGGING_ONLY` (top of the file) already handles
this; if you still hit it, you're probably running an older copy of the file — pull latest.

## A note on scope

This file does `api`, `web` and `worker`. `landing` and `wiki` aren't in `Dockerfile.services`
yet — they're still only built as part of the all-in-one image (`Dockerfile`). Adding them here
later is the same shape as the other three: another `build` → `push` → `deploy` step chain.

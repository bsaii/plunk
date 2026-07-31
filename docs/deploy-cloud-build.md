# Building and deploying api + web with Cloud Build

`cloudbuild.yaml` (repo root) builds the `api` and `web` images from `Dockerfile.services`,
pushes them to Artifact Registry, updates the two Cloud Run services, and keeps the
`plunk-migrate` Cloud Run Job pointed at the same api image — all on Google's build
infrastructure. Use this instead of running `docker build` in Cloud Shell: the monorepo build
(installing dependencies and compiling every app) is big enough to fill Cloud Shell's small
local disk, and Cloud Build doesn't have that limit.

Only `api` and `web` are wired up for now. `worker`, `landing` and `wiki` can be added the same
way later — each is just another `build` → `push` → `deploy` step chain in the same file.

**BuildKit**: the root `Dockerfile` uses `--mount=type=cache` (a BuildKit-only feature) to cache
the yarn/turbo/npm installs between builds. The `gcr.io/cloud-builders/docker` image Cloud Build
runs doesn't turn BuildKit on by default, so every `docker build` step in `cloudbuild.yaml` sets
`env: ["DOCKER_BUILDKIT=1"]` — without it, the build fails on the first cache-mounted line.

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
```

Then open `cloudbuild.yaml` and edit the `substitutions` block at the top so `_REGION`,
`_AR_REPO`, `_API_SERVICE`, `_WEB_SERVICE` and `_MIGRATE_JOB` match what you found — or leave the
file alone and pass them on the command line instead (shown below), whichever is easier to keep
straight.

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
#    roles/run.admin covers both Cloud Run services (plunk-api, plunk-web)
#    and Cloud Run Jobs (plunk-migrate) — no separate role needed for the job.
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
#    cloudbuild.yaml runs) only ever UPDATES an existing service's image — it
#    can't do the interactive first-time deploy (flags like
#    --allow-unauthenticated only need setting once, and Cloud Build steps
#    have no terminal to prompt you for them). If plunk-api / plunk-web don't
#    exist yet, create them once, by hand, from Cloud Shell:

# Web dashboard — see docs/deploy-cloud-run.md for the full first-deploy flow
# (it also covers the custom-domain / auth-cookie requirements).

# API — same shape, with the API's own env vars (DATABASE_URL, REDIS_URL,
# JWT_SECRET, S3_*, AWS_SES_*, etc. — see apps/api/.env.example):
gcloud run deploy plunk-api \
  --image="us-central1-docker.pkg.dev/$(gcloud config get-value project)/plunk/api:bootstrap" \
  --region=us-central1 \
  --platform=managed \
  --allow-unauthenticated \
  --port=8080 \
  --set-env-vars="DATABASE_URL=...,DIRECT_DATABASE_URL=...,REDIS_URL=...,JWT_SECRET=...,DASHBOARD_URI=..."
# (the --image above is a placeholder tag just to satisfy the first deploy —
#  the very next Cloud Build run replaces it with a real commit-tagged image)

# plunk-migrate (the Cloud Run Job that runs `prisma migrate deploy` off the
# api image) is assumed to already exist — cloudbuild.yaml only ever updates
# its image, it never creates the job. If it doesn't exist yet:
gcloud run jobs create plunk-migrate \
  --image="us-central1-docker.pkg.dev/$(gcloud config get-value project)/plunk/api:bootstrap" \
  --region=us-central1 \
  --command="node_modules/.bin/prisma" \
  --args="migrate,deploy,--schema=packages/db/prisma/schema.prisma" \
  --set-env-vars="DATABASE_URL=...,DIRECT_DATABASE_URL=..."
```

## Running it

From the repo root, on the branch/commit you want to ship:

```bash
gcloud builds submit \
  --config=cloudbuild.yaml \
  --substitutions=_TAG=$(git rev-parse --short HEAD)
```

That single command builds both images tagged with the current commit's short SHA, pushes them
to Artifact Registry, rolls `plunk-api` and `plunk-web` over to the new images, and points
`plunk-migrate` at the same new api image — nothing else about either service's configuration
(env vars, secrets, scaling settings) is touched, and the migrate job is only *updated*, never
executed automatically.

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

## Watching a run / troubleshooting

```bash
# Stream logs for the build you just submitted (gcloud builds submit does this
# automatically unless you passed --async).
gcloud builds log --stream BUILD_ID

# List recent builds and their status.
gcloud builds list --limit=5
```

If `deploy-api`, `deploy-web` or `update-migrate-job` fails with a permissions error, re-check
step 2 of the one-time setup above — that's almost always a missing IAM role on the Cloud Build
service account. If a `docker build` step fails complaining about `--mount` or BuildKit, check
that step still has `env: ["DOCKER_BUILDKIT=1"]` set (see the BuildKit note above).

## A note on scope

This file intentionally does only `api` and `web`. `Dockerfile.services` already has a
`worker-runner` target too (see `docs/deploy-cloud-run.md`'s sibling comment about it); when
you're ready, adding it here is the same three-step chain (`build-worker` → `push-worker` →
`deploy-worker`, deploying to a Cloud Run service or job rather than a request-serving service).
`landing` and `wiki` aren't in `Dockerfile.services` yet — they're still only built as part of
the all-in-one image (`Dockerfile`).

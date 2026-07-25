# Deploying the web dashboard to Cloud Run

Build, push and deploy the `web-runner` image from `Dockerfile.services` as its own Cloud Run
service. The API and worker images from the same file follow the identical build/push flow — only
the target, the service name and the environment differ.

## Prerequisites

```bash
export PROJECT_ID=your-gcp-project
export REGION=europe-west1
export REPO=web          # existing Artifact Registry repository
export PLUNK_VERSION=v0.12.0
export IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/plunk-web:${PLUNK_VERSION}"

gcloud config set project "$PROJECT_ID"

# Let Docker authenticate against the registry (once per machine; Cloud Shell
# resets this when the VM is recycled, so re-run it if a push returns 401/403).
gcloud auth configure-docker "${REGION}-docker.pkg.dev"
```

If the repository does not exist yet:

```bash
gcloud artifacts repositories create "$REPO" \
  --repository-format=docker \
  --location="$REGION" \
  --description="Plunk service images"
```

## 1. Build

The service images build on top of two base stages from the root `Dockerfile`, so the dependency
install and the monorepo compile happen once and are shared by the api, worker and web images.
Build them first:

```bash
docker build --platform linux/amd64 --target builder \
  -t "plunk-builder:${PLUNK_VERSION}" -f Dockerfile .

docker build --platform linux/amd64 --target prod-deps \
  -t "plunk-prod-deps:${PLUNK_VERSION}" -f Dockerfile .
```

> **Do not pass `--build-arg API_URI=…` (or the other `*_URI` args) to the builder.** The web bundle
> is compiled with the public placeholder URLs, and the startup entrypoint rewrites them from the
> environment. Overriding the build args bakes your URLs in permanently and leaves the runtime
> rewrite with nothing to match — which is what you want only if you deliberately prefer a
> per-environment image.

Then the web image:

```bash
docker build --platform linux/amd64 \
  --provenance=false --sbom=false \
  --build-arg "PLUNK_VERSION=${PLUNK_VERSION}" \
  --target web-runner \
  -t "$IMAGE" \
  -f Dockerfile.services .
```

`--platform linux/amd64` matters: Cloud Run does not run arm64 images, so building on an Apple
Silicon machine without it produces an image that fails to start. It is a no-op in Cloud Shell,
which is already amd64.

`--provenance=false --sbom=false` suppresses the SLSA provenance and SBOM attestations BuildKit
attaches by default when pushing. Without them the push produces an OCI image *index* with extra
`unknown/unknown` manifest entries — visible as extra untagged entries in Artifact Registry, and a
source of `Container manifest type ... must support amd64/linux` errors on deploy. If your Docker
rejects the flags, use `docker buildx build`, or set `BUILDX_NO_DEFAULT_ATTESTATIONS=1` once.

### Building in Cloud Shell

The Cloud Shell VM is an `e2-small` (2 GB RAM) with a modest boot disk, and this build installs the
whole monorepo's dependencies and runs three Next.js builds. It can work, but `next build` is
memory-hungry — if you hit an OOM kill (exit code 137) or `no space left on device`, reclaim room
with `docker system prune -af` and retry, and if it still fails, build on a machine with more
headroom or move the build to Cloud Build with a larger machine type
(`gcloud builds submit --machine-type=e2-highcpu-8`), which needs a `cloudbuild.yaml` describing the
same three build steps.

## 2. Smoke test before pushing

```bash
scripts/smoke-test-web-image.sh "$IMAGE"
```

This starts the container the way Cloud Run will — non-default `$PORT`, 512Mi, no `HOSTNAME`
override — and checks the failure modes that leave a container *running* but the dashboard broken:
missing `.next/static` or `public` assets, a bind address the container does not own, and a
placeholder API URL that never got rewritten. Exits non-zero and dumps the container log on failure.

## 3. Push

```bash
docker push "$IMAGE"
```

Confirm what actually landed — with the attestation flags above this lists exactly one entry:

```bash
gcloud artifacts docker images list \
  "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}" --include-tags
```

## 4. Deploy

The dashboard needs to know its own public URL, which Cloud Run only assigns on the first deploy.
Deploy once, read the URL back, then set it:

```bash
gcloud run deploy plunk-web \
  --image="$IMAGE" \
  --region="$REGION" \
  --platform=managed \
  --allow-unauthenticated \
  --port=8080 \
  --cpu=1 \
  --memory=512Mi \
  --min-instances=0 \
  --max-instances=10 \
  --set-env-vars="API_URI=https://plunk-api.example.com,LANDING_URI=https://www.example.com,WIKI_URI=https://docs.example.com"

DASHBOARD_URI=$(gcloud run services describe plunk-web \
  --region="$REGION" --format='value(status.url)')

gcloud run services update plunk-web \
  --region="$REGION" \
  --update-env-vars="DASHBOARD_URI=${DASHBOARD_URI}"
```

Redeploying a new image later is just the build/push above plus:

```bash
gcloud run deploy plunk-web --image="$IMAGE" --region="$REGION"
```

Environment variables set on the service are preserved across deploys — you only re-pass
`--set-env-vars` when a value changes.

## Environment variables

The dashboard is a pure frontend: it holds no database, Redis or S3 credentials, and talks to the
API over HTTP. Everything it needs is the four URLs.

| Variable        | Required | Default (if unset)      | Description                                                                 |
| --------------- | -------- | ----------------------- | --------------------------------------------------------------------------- |
| `API_URI`       | Yes      | `http://localhost:8080` | Public URL of the Plunk API service. Every dashboard request goes here.      |
| `DASHBOARD_URI` | Yes      | `http://localhost:3000` | This service's own public URL. Used for absolute links, sitemap and OAuth returns. |
| `LANDING_URI`   | No       | `https://www.useplunk.com` | Marketing site URL. Only used for outbound links; leave unset if not self-hosting it. |
| `WIKI_URI`      | No       | `https://docs.useplunk.com` | Docs site URL, used by in-app help links.                                 |
| `PORT`          | No       | `8080`                  | Injected by Cloud Run; the entrypoint honours it. Do not set it manually.    |
| `NODE_ENV`      | No       | `production`            | Already set in the image.                                                    |

All four `*_URI` values must include the scheme and no trailing slash (`https://app.example.com`).
The entrypoint mirrors them onto the matching `NEXT_PUBLIC_*` names, so there is no need to set both.

### These values must line up with the API service

Two settings on the **API** service are checked against the dashboard's origin, and a mismatch fails
in ways that look like a broken dashboard rather than a misconfiguration:

- The API's `DASHBOARD_URI` is its CORS allowlist entry. If it is not byte-identical to the URL the
  browser loads the dashboard from, every authenticated request is rejected by CORS.
- The API's `API_URI` decides the auth cookie's `Secure`/`SameSite` flags and its `Domain`.

### Custom domains are effectively required

The API derives the auth cookie domain from the last two labels of `API_URI`'s hostname. On the
default Cloud Run hostnames (`https://plunk-api-abc123-ew.a.run.app`) that produces `Domain=.run.app`
— and because `run.app` is on the Public Suffix List, browsers silently drop the cookie. Login then
appears to succeed and the dashboard immediately behaves as logged out.

Map both services onto subdomains of a domain you control before using it for real:

```bash
gcloud beta run domain-mappings create --service=plunk-web \
  --domain=app.example.com --region="$REGION"

gcloud beta run domain-mappings create --service=plunk-api \
  --domain=api.example.com --region="$REGION"
```

Then set `API_URI=https://api.example.com` and `DASHBOARD_URI=https://app.example.com` on **both**
services (the shared `.example.com` cookie domain is what makes the session work across the two).

## Scaling notes

- **`--min-instances=0`** is fine for internal dashboards, at the cost of a cold start (a few
  seconds) on the first request. Use `--min-instances=1` if that matters.
- **`--memory=512Mi`** is enough for the Next.js server. The startup URL rewrite edits files on the
  container's in-memory filesystem, which counts against the memory limit, but it touches only the
  handful of built files listed in the URL manifest.
- **`--allow-unauthenticated`** is required for a public dashboard — Plunk does its own JWT auth.
  Drop it only if you put IAP or another proxy in front.
- The dashboard is stateless, so `--max-instances` can be raised freely; the API and database are
  the scaling constraint, not this service.

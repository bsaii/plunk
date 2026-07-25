#!/usr/bin/env bash
#
# Build and deploy Plunk to Cloud Run from a checkout.
#
#   yarn deploy                    # api + worker + web, with migrations
#   yarn deploy --only web         # just the dashboard
#   yarn deploy --no-migrate       # skip the migration job
#   yarn deploy --migrate-only     # run migrations, deploy nothing
#   yarn deploy --dry-run          # print the gcloud invocation and stop
#
# The build itself runs in Cloud Build, not locally: no Docker daemon needed,
# no `--platform linux/amd64` to forget, and the layer cache is shared across
# machines and with the GitHub trigger.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$REPO_ROOT/deploy/config.env"

TARGETS="api,worker,web"
RUN_MIGRATIONS="true"
TAG=""
DRY_RUN="false"
ASSUME_YES="false"

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^#\s\?//'
  cat <<'EOF'

Options:
  --only a,b       Comma-separated subset of: api, worker, web
  --tag TAG        Override the image tag (default: git short sha)
  --no-migrate     Do not run the migration job
  --migrate-only   Run the migration job and deploy nothing
  --dry-run        Print what would be submitted, change nothing
  -y, --yes        Skip the confirmation prompt
  -h, --help       This message

Note: the build source is your WORKING TREE, not HEAD. Uncommitted changes are
included, which is usually what you want from a deploy command, but it does mean
a dirty tree ships code that is not in git. Such builds are tagged '-dirty'.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)        TARGETS="${2:-}"; shift 2 ;;
    --only=*)      TARGETS="${1#*=}"; shift ;;
    --tag)         TAG="${2:-}"; shift 2 ;;
    --tag=*)       TAG="${1#*=}"; shift ;;
    --no-migrate)  RUN_MIGRATIONS="false"; shift ;;
    --migrate-only) TARGETS=""; RUN_MIGRATIONS="true"; shift ;;
    --dry-run)     DRY_RUN="true"; shift ;;
    -y|--yes)      ASSUME_YES="true"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown option: $1 (try --help)" ;;
  esac
done

# --- Configuration -----------------------------------------------------------
[[ -f "$CONFIG_FILE" ]] || die "$CONFIG_FILE not found.
Copy the template and fill it in:
  cp deploy/config.example.env deploy/config.env"

# shellcheck disable=SC1090
set -a; source "$CONFIG_FILE"; set +a

for required in PROJECT_ID REGION AR_REPO; do
  [[ -n "${!required:-}" ]] || die "$required is not set in $CONFIG_FILE"
done

: "${API_SERVICE:=plunk-api}"
: "${WEB_SERVICE:=plunk-web}"
: "${WORKER_POOL:=plunk-worker}"
: "${WORKER_INSTANCES:=1}"
: "${MIGRATE_JOB:=}"
: "${RUNTIME_SA:=}"
: "${BUILD_SA:=}"
: "${API_SECRETS:=}"
: "${WORKER_SECRETS:=}"
: "${VPC_CONNECTOR:=}"
: "${CLOUDSQL_INSTANCES:=}"

command -v gcloud >/dev/null || die "gcloud not found. Install the Google Cloud CLI."

gcloud auth print-access-token >/dev/null 2>&1 \
  || die "not authenticated. Run: gcloud auth login"

for target in ${TARGETS//,/ }; do
  case "$target" in
    api|worker|web) ;;
    *) die "unknown target '$target'. Valid: api, worker, web" ;;
  esac
done

if [[ -z "$TARGETS" && ( "$RUN_MIGRATIONS" != "true" || -z "$MIGRATE_JOB" ) ]]; then
  die "nothing to do: no deploy targets and no migration job to run"
fi

# --- Tag ---------------------------------------------------------------------
# Tag by commit so a deployed revision can always be traced back to source.
if [[ -z "$TAG" ]]; then
  TAG="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "notag")"
  if ! git -C "$REPO_ROOT" diff --quiet HEAD 2>/dev/null; then
    TAG="${TAG}-dirty"
  fi
fi

# --- Summary -----------------------------------------------------------------
cat <<EOF

  Project     ${PROJECT_ID}
  Region      ${REGION}
  Registry    ${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}
  Tag         ${TAG}
  Deploying   ${TARGETS:-(nothing)}
  Migrations  $(if [[ "$RUN_MIGRATIONS" == "true" && -n "$MIGRATE_JOB" ]]; then echo "job ${MIGRATE_JOB}"; else echo "skipped"; fi)

EOF

if [[ "$TAG" == *-dirty ]]; then
  echo "  ! Working tree is dirty — this deploys code that is not committed."
  echo
fi

SUBSTITUTIONS="_REGION=${REGION}"
SUBSTITUTIONS+=",_AR_REPO=${AR_REPO}"
SUBSTITUTIONS+=",_TAG=${TAG}"
SUBSTITUTIONS+=",_TARGETS=${TARGETS}"
SUBSTITUTIONS+=",_API_SERVICE=${API_SERVICE}"
SUBSTITUTIONS+=",_WEB_SERVICE=${WEB_SERVICE}"
SUBSTITUTIONS+=",_WORKER_POOL=${WORKER_POOL}"
SUBSTITUTIONS+=",_WORKER_INSTANCES=${WORKER_INSTANCES}"
SUBSTITUTIONS+=",_MIGRATE_JOB=${MIGRATE_JOB}"
SUBSTITUTIONS+=",_RUN_MIGRATIONS=${RUN_MIGRATIONS}"
SUBSTITUTIONS+=",_RUNTIME_SA=${RUNTIME_SA}"
SUBSTITUTIONS+=",_VPC_CONNECTOR=${VPC_CONNECTOR}"
SUBSTITUTIONS+=",_CLOUDSQL_INSTANCES=${CLOUDSQL_INSTANCES}"

# Secret maps contain commas, which is also the substitution separator. gcloud
# supports an alternate delimiter declared by a leading ^sep^.
SUBSTITUTION_ARG="^;;^${SUBSTITUTIONS//,/;;}"
SUBSTITUTION_ARG+=";;_API_SECRETS=${API_SECRETS}"
SUBSTITUTION_ARG+=";;_WORKER_SECRETS=${WORKER_SECRETS}"

SUBMIT=(gcloud builds submit
  --project="$PROJECT_ID"
  --config="$REPO_ROOT/cloudbuild.yaml"
  --substitutions="$SUBSTITUTION_ARG"
)
if [[ -n "$BUILD_SA" ]]; then
  SUBMIT+=(--service-account="projects/${PROJECT_ID}/serviceAccounts/${BUILD_SA}")
fi
SUBMIT+=("$REPO_ROOT")

if [[ "$DRY_RUN" == "true" ]]; then
  echo "Would run:"
  printf '  %q' "${SUBMIT[@]}"
  echo
  exit 0
fi

if [[ "$ASSUME_YES" != "true" ]]; then
  read -r -p "Deploy? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

"${SUBMIT[@]}"

echo
echo "Deployed tag ${TAG}. Roll back with:"
echo "  gcloud run services update-traffic ${API_SERVICE} --region=${REGION} --to-revisions=REVISION=100"
echo "  gcloud run worker-pools update ${WORKER_POOL} --region=${REGION} --image=.../plunk-worker:PREVIOUS_TAG"

# Deploying from GitHub without deploy keys

Notes on the pattern this repo uses, and how to apply it to other repos.

## Why the deploy-key workflow does not carry over

The usual small-scale setup is: put a read-only deploy key on a server, and have the server
`git pull` and restart. It works, but the properties are worth naming, because they are what
changes here:

- **The server is the build machine.** Build tooling, versions and caches have to exist in
  production. A build that fails halfway leaves a half-updated checkout.
- **There is no artifact.** "What is running" is a working directory. Rolling back means
  checking out an older commit and rebuilding — with whatever dependency versions resolve *today*.
- **The key is long-lived and copied.** It sits on a disk you have to remember to rotate, and it is
  as valid on a compromised box as on a healthy one.

Cloud Run cannot pull anything. It runs a container image, so the image *is* the artifact — built
once, addressed by digest, deployed by reference. Once the artifact exists, "how does the server get
the code" stops being a question, and the only remaining one is "who is allowed to build and
deploy".

## The setup here

```
git push ──▶ Cloud Build trigger ──▶ build ──▶ Artifact Registry ──▶ gcloud run deploy
                    ▲
              cloudbuild.yaml
                    ▲
yarn deploy ────────┘
```

Both entry points run the same `cloudbuild.yaml`. There is no second pipeline to keep in sync, and
no "works via the trigger but not locally" class of bug.

```bash
yarn deploy:trigger    # scripts/setup-cloud-build-trigger.sh
```

The one step that cannot be scripted is installing the Cloud Build GitHub App — it is an OAuth
handshake. The script detects a missing connection and prints the console URL rather than failing
three commands later.

What that buys over a deploy key:

- **No key material anywhere.** The grant lives in the GitHub App installation, scoped per
  repository, revocable from GitHub's UI without touching any server.
- **Least privilege, split two ways.** The build identity (`BUILD_SA`) can write images and deploy
  but has no reason to read runtime secrets. The runtime identity (`RUNTIME_SA`) can read secrets
  but cannot push images or change deployments. Neither is your user account.
- **Traceability.** Every image is tagged with the commit that produced it, so a running revision
  maps to a commit, and a rollback is a tag you already have.

## Deploy by SHA, never by `latest`

`latest` cannot be rolled back to — it means something different tomorrow. Images here are tagged
with the commit SHA and deployed by that tag, which is why rollback is a one-liner
(`gcloud run services update-traffic --to-revisions=...`) rather than a rebuild. `:cache` tags exist
only to warm the next build's layer cache; nothing is ever deployed from them.

## The alternative: GitHub Actions + Workload Identity Federation

If you would rather keep CI in one place — this repo already runs `ci.yml` and `docker-publish.yml`
in Actions — the keyless equivalent is Workload Identity Federation: GitHub's OIDC token is
exchanged for short-lived Google credentials, so no service-account JSON key is ever created or
stored as a repo secret.

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: google-github-actions/auth@v2
    with:
      workload_identity_provider: projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/POOL/providers/PROVIDER
      service_account: plunk-build@PROJECT_ID.iam.gserviceaccount.com
  - uses: google-github-actions/setup-gcloud@v2
  - run: gcloud builds submit --config=cloudbuild.yaml --substitutions=_TAG=${{ github.sha }}
```

Note the last line: it delegates to the same `cloudbuild.yaml`. The choice between Cloud Build
triggers and Actions is about where you want the logs and the queue, not about duplicating the
build.

Pick Cloud Build triggers when the build is heavy and GCP-native (it is here — a monorepo Docker
build benefits from the bigger machine types and the registry cache). Pick Actions when the deploy
is one step in a workflow that also runs tests and linting, and you want a single check to gate it.

Whichever you choose, do not create a service-account JSON key. Both paths above avoid one, and a
key in a repo secret is the deploy key problem again with more privilege.

## Reusing this on another repo

The pieces are repo-agnostic. Copy and adjust:

| File                              | What to change                                            |
| --------------------------------- | --------------------------------------------------------- |
| `cloudbuild.yaml`                  | The build steps and the deploy targets.                    |
| `.gcloudignore`                    | What gets uploaded as build source — keep it small.        |
| `deploy/config.example.env`        | Resource names for the new project.                        |
| `deploy/env/*.yaml`                | The non-secret runtime environment per workload.           |
| `scripts/deploy.sh`                | Usually unchanged; it just assembles substitutions.        |
| `scripts/gcp-bootstrap.sh`         | The APIs, roles and secrets that project needs.            |
| `scripts/setup-cloud-build-trigger.sh` | Usually unchanged.                                     |

The parts worth keeping regardless of the app:

1. One build definition, two entry points (manual and triggered).
2. A bootstrap script, so project setup is reproducible rather than a console session nobody
   wrote down.
3. Config as committed files that *replace* runtime state on deploy, so the console cannot drift.
4. Secrets by reference, never as build substitutions or image layers.
5. Commit-SHA tags, so every deploy is traceable and reversible.

## Things that bite

- **`.gcloudignore` replaces `.gitignore` for uploads; it does not chain to it.** Once the file
  exists, anything the build needs must survive its patterns. Here that includes `.yarn/releases`
  (the pinned Yarn binary) — easy to exclude by accident with a broad `.yarn` rule.
- **A user-specified build service account requires `logging: CLOUD_LOGGING_ONLY`** in
  `cloudbuild.yaml`, or the build fails immediately complaining about the logs bucket.
- **The top-level `images:` field pushes only after every step finishes.** Anything that deploys
  within the same build must `docker push` explicitly first, or it deploys a tag that does not exist
  yet.
- **Substitution values containing commas** (secret maps) need gcloud's alternate-delimiter syntax:
  `--substitutions="^;;^KEY=a,b;;OTHER=c"`.

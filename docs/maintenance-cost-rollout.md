# Maintenance cost reduction

## Behavior

The segment maintenance schedule changes from every five minutes to every
15 minutes. Domain verification and idempotency cleanup remain hourly; API
request and email body cleanup remain daily.

The segment sweep selects only active projects that have segments. For mixed
projects, the count-only pass excludes tracked segments whose membership pass
already updated their counts. Other callers of `refreshAllMemberCounts` retain
the existing all-segments behavior.

The maintenance CLI takes a Redis lease per task. An overlapping execution logs
a skip and exits successfully; different tasks can run together. Lock acquisition
fails closed if Redis is unavailable. A unique owner token and atomic
compare-and-delete prevent an old execution from releasing another execution's
lock. Task processors load only after their lease is acquired, so cleanup-only
runs avoid importing the segment processor's BullMQ queue instances.

A nine-minute process deadline bounds stalled work; the lease lasts ten minutes.
The process exits on deadline rather than releasing a lock while work continues.
A crashed process leaves the lease to expire. An immediate retry may skip until
expiry; the next scheduled run does the work.

Terraform ignores the maintenance image's deployment-client metadata as well as
the image itself, because Cloud Build's `gcloud` deployment owns those values.
This prevents schedule-only plans from updating the Cloud Run Job.

## Rollout checklist

1. Review and merge into staging, then test against isolated staging services.
   A Git branch alone does not provision an environment. Staging must not share
   the production Redis or PostgreSQL database.
2. Check automation timing before changing the schedule. Segment entry/exit
   events now have up to 15 minutes of polling delay plus runtime. Short-lived
   membership transitions between polls can be missed. If five-minute detection
   is required, keep that cadence or separate tracked membership sweeps from
   display-only counts.
3. Check the runtime distribution of all five tasks, including daily cleanups.
   A backlog approaching nine minutes needs bounded batches/checkpointing before
   deployment of the watchdog. Use a 600-second Cloud Run task timeout and one
   task per execution. The application watchdog is 540 seconds and the Redis
   lease is 600 seconds. Review longer workloads before increasing these
   together; execution lifetime must remain bounded before lease replacement.
4. All maintenance executions within one environment must share its Redis
   database. Credentials need `SET` with `NX`/`PX` and `EVAL`/`GET`/`DEL`
   permissions. Keep `QUEUE_BACKEND=cloud-tasks` on the GCP API to avoid also
   scheduling legacy BullMQ maintenance sweeps.
5. Promote the reviewed code to production using the existing deployment
   process described in `terraform/gcp/operations.md`. Verify the maintenance
   job uses the newly built maintenance image and its `maintenance-runner`
   entrypoint, without a command override.
6. Use the deployment's existing Terraform backend and canonical input file.
   Do not apply using placeholder examples or a new/empty state. For a scoped
   rollout, save a plan targeting only the segment Scheduler resource:

   ```bash
   terraform -chdir=terraform/gcp plan \
     -input=false -lock-timeout=60s \
     -var-file="$PLUNK_TFVARS" \
     '-target=google_cloud_scheduler_job.maintenance["segment-count"]' \
     -out="$PLUNK_PLAN"
   terraform -chdir=terraform/gcp show "$PLUNK_PLAN"
   ```

   Set `PLUNK_TFVARS` and `PLUNK_PLAN` to absolute paths. Inspect the saved plan
   before applying. The expected change is one in-place Scheduler update from
   `*/5 * * * *` to `*/15 * * * *`, or no changes if already applied. Do not
   proceed with additions, deletions, replacements or unrelated attribute
   updates. Apply only the saved, reviewed plan, then verify with another scoped
   plan and a read of the live schedule. Targeted plans do not establish that the
   rest of the stack is free of drift.
7. Observe scheduled executions for at least a day. Confirm duration logs,
   expected membership events, no sustained deadline/Redis errors, and no
   repeated lease skips when nothing should be running. Check processor error
   logs too: existing per-segment error handling can report a successful sweep
   despite individual segment failures. Do not force-run cleanup jobs merely
   for smoke testing.

The lease prevents concurrent maintenance CLI sweeps of the same task; it does
not provide exactly-once events, serialize separate BullMQ workers, or protect
against Redis data loss/eviction. Existing task retry configuration is unchanged.

Keep production state, tfvars, plan files and detailed operation records private.
They may contain sensitive deployment configuration and do not belong in a PR.

## Rollback

Restore only the segment schedule to `*/5 * * * *`, generate a new targeted
saved plan, and verify a single in-place update before applying. Application
rollback uses the previous maintenance image through the deployment process;
it does not require deleting infrastructure or Redis data.

## Cost model

The proposed schedule produces 4,380 executions per 30 days instead of 10,140
(57% fewer). With the repository defaults of 1 vCPU and 512 MiB in us-central1,
and assuming every execution uses at most the one-minute billed minimum, gross
compute is $4.9932. Five Scheduler definitions cost about $0.4839 per 30 days,
giving **$5.48 before free-tier credits**.

| Task | Runs per 30 days | Compute under the one-minute assumption |
| --- | ---: | ---: |
| Segment refresh | 2,880 | $3.2832 |
| Domain verification | 720 | $0.8208 |
| Idempotency cleanup | 720 | $0.8208 |
| API request cleanup | 30 | $0.0342 |
| Email body cleanup | 30 | $0.0342 |

This is a conditional estimate, not a measured bill or cost cap. It excludes
database/Redis, network, logs, image storage and build costs. Longer runs and
retries cost more. Execution wall time can include platform overhead; use billed
instance time and billing SKUs to measure actual savings.

Sources: [Cloud Run pricing](https://cloud.google.com/run/pricing) and
[Cloud Scheduler pricing](https://cloud.google.com/scheduler/pricing).

## Validation

```bash
node .yarn/releases/yarn-4.9.1.cjs workspaces focus api plunk
node .yarn/releases/yarn-4.9.1.cjs vitest run --config vitest.maintenance.config.ts
```

The focused suite covers mixed/tracked-only/empty segment sweeps, compatibility
of all-segment refresh callers, lease contention, acquisition failure, task
failure, release failure and forced exit before lease expiry. The maintenance
workflow runs these tests on PRs targeting staging/production; the existing
broader CI workflow only targets `next`.

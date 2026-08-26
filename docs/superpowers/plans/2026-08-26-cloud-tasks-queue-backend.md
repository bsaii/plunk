# Cloud Tasks Queue Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow Plunk's seven real-time queues to use authenticated Cloud Tasks HTTP delivery without changing QueueService callers, while retaining BullMQ as the self-hosted default.

**Architecture:** QueueService keeps its existing public methods and delegates real-time enqueues to a QueueAdapter selected by `REALTIME_QUEUE_BACKEND`. `QUEUE_BACKEND` remains exclusively responsible for Phase 1 maintenance scheduling. The Cloud Tasks adapter sends a small typed envelope to `worker-server`, persists pollable import and bulk jobs in Redis, and chains delays longer than Cloud Tasks' 30-day limit. BullMQ workers call the same extracted processors and update the same progress store.

**Tech Stack:** TypeScript, Express 5, BullMQ, ioredis, `@google-cloud/tasks`, `google-auth-library`, Vitest.

**Spec:** [Phase 2 design comment](https://github.com/bsaii/plunk/pull/23#issuecomment-5428023382)

## Global Constraints

- Preserve every existing QueueService method name and caller argument list.
- `REALTIME_QUEUE_BACKEND` defaults to `bullmq`; self-hosted deployments retain BullMQ behavior.
- Keep the existing `QUEUE_BACKEND=cloud-tasks` maintenance configuration unchanged until Phase 3 explicitly enables the new real-time backend.
- Do not modify Terraform, Cloud Build worker deployment, or retire the Worker Pool; those are Phase 3.
- Cloud Tasks receives only JSON envelopes smaller than 100 KB; import CSV data remains in Redis.
- Delays longer than 30 days are rescheduled in 30-day hops.
- Worker HTTP routes accept only Google-issued OIDC tokens whose audience equals `CLOUD_TASKS_AUDIENCE`.
- Cloud Tasks cancellation uses execution-time project-disabled checks; BullMQ retains queue introspection cancellation.

---

### Task 1: Define queue contracts and regression tests

**Files:**
- Create: `apps/api/src/queue/types.ts`
- Create: `apps/api/src/queue/__tests__/types.test.ts`

**Interfaces:**
- Produces `QueueAdapter`, `QueueName`, `QueuedJob`, `QueueJobStatus`, `QueueJobContext`, and `CloudTaskEnvelope<T>`.
- `QueuedJob` exposes at least `{id: string}` so existing controllers remain source-compatible.

- [ ] **Step 1: Write the failing contract tests**

```ts
import {describe, expect, it} from 'vitest';
import {MAX_CLOUD_TASK_DELAY_MS, nextCloudTaskSchedule} from '../types.js';

describe('nextCloudTaskSchedule', () => {
  it('caps a 45-day delay at the Cloud Tasks 30-day horizon', () => {
    expect(nextCloudTaskSchedule(45 * 24 * 60 * 60 * 1000, 0)).toEqual({
      scheduleAt: MAX_CLOUD_TASK_DELAY_MS,
      notBefore: 45 * 24 * 60 * 60 * 1000,
    });
  });
});
```

- [ ] **Step 2: Run the focused test and verify it fails because the module does not exist**

Run: `yarn vitest run apps/api/src/queue/__tests__/types.test.ts --config vitest.phase2.config.ts`

Expected: module-not-found failure for `../types.js`.

- [ ] **Step 3: Implement the minimal queue contract**

```ts
export const MAX_CLOUD_TASK_DELAY_MS = 30 * 24 * 60 * 60 * 1000;
export function nextCloudTaskSchedule(delayMs: number, now = Date.now()) {
  return {scheduleAt: now + Math.min(Math.max(delayMs, 0), MAX_CLOUD_TASK_DELAY_MS), notBefore: now + Math.max(delayMs, 0)};
}
```

Define the adapter operation names for `email`, `campaign`, `scheduled`, `workflow`, `import`, `bulk-contact-actions`, and `meter`.

- [ ] **Step 4: Run the focused test and verify it passes**

Run: `yarn vitest run apps/api/src/queue/__tests__/types.test.ts --config vitest.phase2.config.ts`

Expected: one passing test.

- [ ] **Step 5: Commit**

```bash
git add apps/api/src/queue/types.ts apps/api/src/queue/__tests__/types.test.ts
git commit -m "feat(queue): add backend adapter contracts"
```

### Task 2: Add the Redis progress store and backend adapters

**Files:**
- Create: `apps/api/src/queue/progress-store.ts`
- Create: `apps/api/src/queue/bullmq-adapter.ts`
- Create: `apps/api/src/queue/cloud-tasks-adapter.ts`
- Create: `apps/api/src/queue/adapter.ts`
- Create: `apps/api/src/queue/__tests__/progress-store.test.ts`
- Create: `apps/api/src/queue/__tests__/cloud-tasks-adapter.test.ts`
- Modify: `apps/api/package.json`
- Modify: `yarn.lock`
- Modify: `apps/api/src/app/constants.ts`

**Interfaces:**
- Consumes `QueueAdapter`, `CloudTaskEnvelope`, and `nextCloudTaskSchedule` from Task 1.
- Produces `getQueueAdapter()` and a progress store with `create`, `markActive`, `updateProgress`, `complete`, `fail`, and `get`.

- [ ] **Step 1: Write the failing adapter tests**

```ts
it('stores a large import payload and sends only its job id to Cloud Tasks', async () => {
  const job = await adapter.enqueue('import', {projectId: 'p1', csvData: 'x'.repeat(200_000), filename: 'a.csv'});
  expect(taskClient.createTask).toHaveBeenCalledWith(expect.objectContaining({task: expect.objectContaining({httpRequest: expect.objectContaining({body: expect.not.stringContaining('x'.repeat(100))})})}));
  expect(await progressStore.get(job.id)).toMatchObject({data: {projectId: 'p1'}});
});
```

- [ ] **Step 2: Run the focused tests and verify they fail because no adapter exists**

Run: `yarn vitest run apps/api/src/queue/__tests__/progress-store.test.ts apps/api/src/queue/__tests__/cloud-tasks-adapter.test.ts --config vitest.phase2.config.ts`

Expected: module-not-found failure for the adapter and progress-store files.

- [ ] **Step 3: Add runtime dependencies and implement adapters**

Run: `yarn workspace api add @google-cloud/tasks google-auth-library`

Use the Cloud Tasks v2 client and explicit task names derived from a non-sequential UUID job id. Create HTTP POST tasks with an OIDC service-account token. Persist import and bulk job data before enqueueing; task bodies contain `{jobId, queue, data? , notBefore}` and omit `data` for persisted jobs. The BullMQ adapter wraps existing queues and leaves maintenance and segment-count queues on BullMQ.

- [ ] **Step 4: Run the focused tests and verify they pass**

Run: `yarn vitest run apps/api/src/queue/__tests__/progress-store.test.ts apps/api/src/queue/__tests__/cloud-tasks-adapter.test.ts --config vitest.phase2.config.ts`

Expected: all focused adapter tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/api/package.json yarn.lock apps/api/src/app/constants.ts apps/api/src/queue
git commit -m "feat(queue): add Cloud Tasks and BullMQ adapters"
```

### Task 3: Delegate QueueService without changing its public surface

**Files:**
- Modify: `apps/api/src/services/QueueService.ts`
- Create: `apps/api/src/queue/__tests__/queue-service.test.ts`

**Interfaces:**
- Consumes `getQueueAdapter()` from Task 2.
- Produces the unchanged static QueueService methods returning `QueuedJob`-compatible results.

- [ ] **Step 1: Write failing façade tests**

```ts
it('uses the workflow adapter operation while retaining queueWorkflowStep arguments', async () => {
  await QueueService.queueWorkflowStep('execution-1', 'step-1', 5000);
  expect(adapter.enqueue).toHaveBeenCalledWith('workflow', {executionId: 'execution-1', stepId: 'step-1', type: 'process-step'}, expect.objectContaining({delayMs: 5000}));
});
```

- [ ] **Step 2: Run the focused test and verify it fails against the direct BullMQ implementation**

Run: `yarn vitest run apps/api/src/queue/__tests__/queue-service.test.ts --config vitest.phase2.config.ts`

Expected: the adapter spy has not been called.

- [ ] **Step 3: Replace real-time QueueService internals with adapter delegation**

Keep `queueSegmentCountUpdate`, the five maintenance queues, pause/resume/cleanup and BullMQ cancellation logic intact. Select the real-time adapter from `REALTIME_QUEUE_BACKEND`; make `getImportJobStatus` and `getBulkActionJobStatus` read the shared progress store when that backend is Cloud Tasks.

- [ ] **Step 4: Run the focused test and verify it passes**

Run: `yarn vitest run apps/api/src/queue/__tests__/queue-service.test.ts --config vitest.phase2.config.ts`

Expected: focused façade tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/api/src/services/QueueService.ts apps/api/src/queue/__tests__/queue-service.test.ts
git commit -m "refactor(queue): route real-time jobs through adapter"
```

### Task 4: Extract shared processors and record pollable progress

**Files:**
- Modify: `apps/api/src/jobs/email-processor.ts`
- Modify: `apps/api/src/jobs/campaign-processor.ts`
- Modify: `apps/api/src/jobs/scheduled-processor.ts`
- Modify: `apps/api/src/jobs/workflow-processor-queue.ts`
- Modify: `apps/api/src/jobs/import-processor.ts`
- Modify: `apps/api/src/jobs/bulk-contact-processor.ts`
- Modify: `apps/api/src/jobs/meter-processor.ts`
- Modify: `apps/api/src/jobs/__tests__/import-processor.test.ts`
- Modify: `apps/api/src/jobs/__tests__/scheduled-processor.test.ts`

**Interfaces:**
- Produces `processEmailJob`, `processCampaignJob`, `processScheduledCampaignJob`, `processWorkflowJob`, `processImportJob`, `processBulkContactJob`, and `processMeterJob`.
- Each accepts typed data and an optional `QueueJobContext` for progress; BullMQ workers adapt `job.updateProgress` to that context.

- [ ] **Step 1: Write failing processor tests**

```ts
it('reports import progress through the backend-neutral context', async () => {
  const progress = vi.fn();
  await processImportJob(importData, {updateProgress: progress});
  expect(progress).toHaveBeenLastCalledWith(100);
});
```

- [ ] **Step 2: Run the affected tests and verify they fail because pure processor exports are absent**

Run: `yarn vitest run apps/api/src/jobs/__tests__/import-processor.test.ts apps/api/src/jobs/__tests__/scheduled-processor.test.ts --config vitest.phase2.config.ts`

Expected: named-export failure for the extracted processor.

- [ ] **Step 3: Extract processor functions and add disabled-project guards**

Keep Worker constructors as thin adapters. Before campaign, workflow, import, and bulk execution, load the owning project and return without side effects when `disabled` is true. Record queued/active/progress/completed/failed states for import and bulk jobs through the shared progress store.

- [ ] **Step 4: Run the affected tests and verify they pass**

Run: `yarn vitest run apps/api/src/jobs/__tests__/import-processor.test.ts apps/api/src/jobs/__tests__/scheduled-processor.test.ts --config vitest.phase2.config.ts`

Expected: all exercised processor tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/api/src/jobs apps/api/src/queue/progress-store.ts
git commit -m "refactor(worker): share queue processors across backends"
```

### Task 5: Add the authenticated Cloud Tasks worker server

**Files:**
- Create: `apps/api/src/jobs/worker-server.ts`
- Create: `apps/api/src/jobs/__tests__/worker-server.test.ts`
- Modify: `apps/api/package.json`
- Modify: `Dockerfile.services`

**Interfaces:**
- Consumes extracted `process*Job` functions from Task 4 and `CloudTaskEnvelope` from Task 1.
- Exposes POST endpoints `/tasks/email`, `/tasks/campaign`, `/tasks/scheduled`, `/tasks/workflow`, `/tasks/import`, `/tasks/bulk-contact-actions`, and `/tasks/meter`.

- [ ] **Step 1: Write failing HTTP behavior tests**

```ts
it('rejects a task without a bearer token', async () => {
  const response = await request(workerApp).post('/tasks/email').send({jobId: 'job-1'});
  expect(response.status).toBe(401);
});

it('returns 204 after a verified task is processed', async () => {
  verifyIdToken.mockResolvedValue({getPayload: () => ({email: 'cloud-tasks@example.iam.gserviceaccount.com'})});
  const response = await request(workerApp).post('/tasks/email').set('Authorization', 'Bearer token').send({jobId: 'job-1', data: {emailId: 'email-1'}});
  expect(response.status).toBe(204);
});
```

- [ ] **Step 2: Run the focused HTTP tests and verify they fail because the server is absent**

Run: `yarn vitest run apps/api/src/jobs/__tests__/worker-server.test.ts --config vitest.phase2.config.ts`

Expected: module-not-found failure for `worker-server.js`.

- [ ] **Step 3: Implement worker-server and Docker target**

Use Express JSON parsing with a 1 MB limit. Verify bearer tokens using `google-auth-library` and the configured audience before decoding task envelopes. Look up persisted import/bulk data by job id, mark the job active, invoke the extracted processor, mark complete on success, mark failed and return 500 on exceptions. When `notBefore` is still in the future, enqueue another task and return 204 without processing. Add a `worker-server` Docker target and `start:worker-server` script; do not change the existing worker target.

- [ ] **Step 4: Run the focused HTTP tests and verify they pass**

Run: `yarn vitest run apps/api/src/jobs/__tests__/worker-server.test.ts --config vitest.phase2.config.ts`

Expected: authentication and routing tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/api/src/jobs/worker-server.ts apps/api/src/jobs/__tests__/worker-server.test.ts apps/api/package.json Dockerfile.services
git commit -m "feat(worker): add OIDC-protected Cloud Tasks server"
```

### Task 6: Document the opt-in and verify the complete change

**Files:**
- Modify: `apps/api/.env.example`
- Modify: `.env.self-host.example`
- Modify: `apps/wiki/content/docs/self-hosting/environment-variables.mdx`
- Modify: `docs/deploy-cloud-run.md`
- Modify: `docs/deploy-cloud-build.md`

**Interfaces:**
- Documents `REALTIME_QUEUE_BACKEND`, `CLOUD_TASKS_PROJECT_ID`, `CLOUD_TASKS_LOCATION`, `CLOUD_TASKS_WORKER_URL`, `CLOUD_TASKS_AUDIENCE`, and `CLOUD_TASKS_SERVICE_ACCOUNT_EMAIL` as a Phase 3 deployment prerequisite.

- [ ] **Step 1: Update the three required environment-variable references**

State that self-hosters leave both queue-backend variables unset. `QUEUE_BACKEND=cloud-tasks` remains a Phase 1 maintenance setting for the internal GCP deployment; `REALTIME_QUEUE_BACKEND=cloud-tasks` is a Phase 3 activation step and must remain unset in this PR.

- [ ] **Step 2: Build generated Prisma client and typecheck**

Run: `yarn workspace @plunk/db db:generate && yarn workspace api build`

Expected: generated client and API TypeScript compilation complete with exit code 0.

- [ ] **Step 3: Lint changed API files**

Run: `yarn eslint apps/api/src/queue apps/api/src/jobs apps/api/src/services/QueueService.ts`

Expected: exit code 0.

- [ ] **Step 4: Run focused queue and worker tests**

Run: `yarn vitest run apps/api/src/queue/__tests__ apps/api/src/jobs/__tests__/worker-server.test.ts --config vitest.phase2.config.ts`

Expected: all Phase 2 tests pass; the full suite remains dependent on Docker PostgreSQL and Redis.

- [ ] **Step 5: Review the requirements and commit**

Confirm each of the eight Phase 2 design points is covered, confirm Phase 3 Terraform is unchanged, then run:

```bash
git add apps/api/.env.example .env.self-host.example apps/wiki/content/docs/self-hosting/environment-variables.mdx docs/deploy-cloud-run.md docs/deploy-cloud-build.md
git commit -m "docs: describe Cloud Tasks queue prerequisites"
```

## Self-Review

- Spec coverage: Tasks 1–3 implement the adapter/facade; Task 4 implements seven shared processors and disabled-project behavior; Task 5 implements OIDC worker routes and long-delay chaining; Task 6 documents dependencies and verifies the result.
- Placeholder scan: no deferred implementation markers or unspecified error handling remain.
- Type consistency: QueueAdapter and CloudTaskEnvelope are introduced before use; the QueueService continues to expose its existing methods; worker routes consume the same typed payloads produced by the adapter.

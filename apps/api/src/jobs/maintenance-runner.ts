/**
 * Maintenance Cloud Run Job entrypoint
 *
 * Dispatches to one of the 5 scheduled maintenance tasks based on a `--task=<name>`
 * CLI argument (or a MAINTENANCE_TASK env var, for the Cloud Scheduler job-execution
 * override to set either way). One image serves all 5 Cloud Scheduler entries -
 * see terraform/gcp/maintenance.tf for how each schedule supplies its own task.
 *
 * This is the GCP-deployment equivalent of the BullMQ repeatable jobs registered in
 * app.ts for self-hosted deployments (see QUEUE_BACKEND in app/constants.ts).
 */

import signale from 'signale';
import {Redis} from 'ioredis';

import {REDIS_URL} from '../app/constants.js';
import {runWithMaintenanceLock} from './maintenance-lock.js';

// Load only the selected processor, after acquiring its lease. In particular,
// cleanup-only runs do not need the segment processor's BullMQ queue instances.
const TASKS = {
  'domain-verification': async () => (await import('./domain-verification.js')).runDomainVerificationJob(),
  'segment-count': async () => (await import('./segment-count-processor.js')).runSegmentCountJob(),
  'api-request-cleanup': async () => (await import('./api-request-cleanup-processor.js')).runApiRequestCleanupJob(),
  'idempotency-key-cleanup': async () =>
    (await import('./idempotency-key-cleanup-processor.js')).runIdempotencyKeyCleanupJob(),
  'email-body-cleanup': async () => (await import('./email-body-cleanup-processor.js')).runEmailBodyCleanupJob(),
} as const satisfies Record<string, () => Promise<unknown>>;

type TaskName = keyof typeof TASKS;

function parseTaskName(): string | undefined {
  const arg = process.argv.find(a => a.startsWith('--task='));
  if (arg) {
    return arg.slice('--task='.length);
  }
  return process.env.MAINTENANCE_TASK;
}

function isTaskName(name: string | undefined): name is TaskName {
  return name !== undefined && Object.hasOwn(TASKS, name);
}

async function main() {
  const task = parseTaskName();

  if (!isTaskName(task)) {
    signale.error(
      `[MAINTENANCE-RUNNER] Unknown or missing task ${JSON.stringify(task)}. Expected --task=<name> or MAINTENANCE_TASK to be one of: ${Object.keys(TASKS).join(', ')}`,
    );
    process.exit(1);
  }

  // Fail closed if Redis cannot grant the lease. Keep lock commands bounded
  // independently of the legacy application Redis client's retry policy.
  const lockRedis = new Redis(REDIS_URL, {
    family: 4,
    lazyConnect: true,
    connectTimeout: 10000,
    commandTimeout: 10000,
    enableOfflineQueue: false,
    maxRetriesPerRequest: 1,
    retryStrategy: () => null,
  });
  lockRedis.on('error', error => signale.error('[MAINTENANCE-RUNNER] Lock Redis error:', error));

  try {
    await lockRedis.connect();
    await runWithMaintenanceLock(lockRedis, task, TASKS[task]);
  } finally {
    lockRedis.disconnect();
  }
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    signale.error('[MAINTENANCE-RUNNER] Fatal error:', error);
    process.exit(1);
  });

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

import {runApiRequestCleanupJob} from './api-request-cleanup-processor.js';
import {runDomainVerificationJob} from './domain-verification.js';
import {runEmailBodyCleanupJob} from './email-body-cleanup-processor.js';
import {runIdempotencyKeyCleanupJob} from './idempotency-key-cleanup-processor.js';
import {runSegmentCountJob} from './segment-count-processor.js';

const TASKS = {
  'domain-verification': runDomainVerificationJob,
  'segment-count': runSegmentCountJob,
  'api-request-cleanup': runApiRequestCleanupJob,
  'idempotency-key-cleanup': runIdempotencyKeyCleanupJob,
  'email-body-cleanup': runEmailBodyCleanupJob,
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
  return name !== undefined && name in TASKS;
}

async function main() {
  const task = parseTaskName();

  if (!isTaskName(task)) {
    signale.error(
      `[MAINTENANCE-RUNNER] Unknown or missing task ${JSON.stringify(task)}. Expected --task=<name> or MAINTENANCE_TASK to be one of: ${Object.keys(TASKS).join(', ')}`,
    );
    process.exit(1);
  }

  signale.info(`[MAINTENANCE-RUNNER] Running task "${task}"...`);
  await TASKS[task]();
  signale.success(`[MAINTENANCE-RUNNER] Task "${task}" completed successfully`);
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    signale.error('[MAINTENANCE-RUNNER] Fatal error:', error);
    process.exit(1);
  });

/**
 * Background Job: Snooze Sweep
 *
 * Snoozing lets a recipient stop email for a fixed window instead of forever. A snooze is
 * stored as `subscribed = false` plus a `snoozedUntil` date -- not a third subscription state
 * -- so every send path suppresses a snoozed contact through the `subscribed` filter it
 * already has. Nothing in the send paths knows snoozing exists.
 *
 * The consequence is that a snooze has no way to end on its own. This sweep is the other half
 * of the feature: it resubscribes contacts whose date has passed and emits
 * `contact.subscribed` with `reason: 'snooze_expired'`, which is what makes the return visible
 * in the activity feed and able to drive a winback workflow.
 *
 * Runs every five minutes. That is far finer than it needs to be for windows measured in weeks
 * to years, and the cost of a run with nothing due is a single indexed query returning no rows.
 *
 * Re-running is safe: the sweep only ever selects contacts that are still due, so a retry after
 * a failure cannot double-wake anyone it already handled.
 */

import type {SnoozeSweepJobData} from '@plunk/types';
import {type Job, Worker} from 'bullmq';
import signale from 'signale';

import {ContactService} from '../services/ContactService.js';
import {snoozeSweepQueue} from '../services/QueueService.js';

/**
 * Contacts read per query. Small enough that one batch's events finish quickly, large enough
 * that a normal run is one or two round trips.
 */
const BATCH_SIZE = 500;

/**
 * Contacts woken per run.
 *
 * Waking someone is not a cheap write: each one emits `contact.subscribed`, and every one of
 * those runs the workflow trigger match and the WAIT_FOR_EVENT resume. A campaign that snoozed
 * thousands of recipients on the same day would otherwise come due together and put all of that
 * through the workflow engine in a single burst. The cap spreads it over consecutive runs, at a
 * cost of minutes on a window measured in weeks.
 */
const MAX_PER_RUN = 5000;

/**
 * Resubscribe contacts whose snooze has run out. Shared by the BullMQ worker callback and the
 * maintenance Cloud Run Job CLI entrypoint.
 */
export async function runSnoozeSweepJob(): Promise<{resumed: number}> {
  const resumed = await ContactService.resumeExpiredSnoozes({
    batchSize: BATCH_SIZE,
    maxPerRun: MAX_PER_RUN,
  });

  if (resumed > 0) {
    signale.info(`[SNOOZE-SWEEP] Resumed ${resumed} contact(s) whose snooze expired`);
  }

  return {resumed};
}

async function processSweep(_job: Job<SnoozeSweepJobData>): Promise<{resumed: number}> {
  return runSnoozeSweepJob();
}

export function createSnoozeSweepWorker(): Worker<SnoozeSweepJobData> {
  const worker = new Worker<SnoozeSweepJobData>(snoozeSweepQueue.name, processSweep, {
    connection: snoozeSweepQueue.opts.connection,
    // One sweep at a time. Two concurrent runs would select overlapping slices of the same due
    // set; the update is idempotent, but the duplicated events are not -- a contact could be
    // told they were resubscribed twice.
    concurrency: 1,
  });

  worker.on('failed', (job, error) => {
    signale.error(`[SNOOZE-SWEEP] Job ${job?.id} failed:`, error);
  });

  worker.on('error', error => {
    signale.error('[SNOOZE-SWEEP] Worker error:', error);
  });

  return worker;
}

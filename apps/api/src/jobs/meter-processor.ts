/**
 * Background Job: Meter Processor
 * Reliably records Stripe billing meter events with automatic retries
 */

import type {MeterEventJobData} from '@plunk/types';
import {Worker} from 'bullmq';
import signale from 'signale';

import {STRIPE_ENABLED, STRIPE_METER_EVENT_NAME} from '../app/constants.js';
import {stripe} from '../app/stripe.js';
import {meterQueue} from '../services/QueueService.js';

export async function processMeterJob(data: MeterEventJobData): Promise<void> {
  const {customerId, value, idempotencyKey} = data;

  if (!STRIPE_ENABLED || !stripe) {
    return;
  }

  await stripe.billing.meterEvents.create({
    event_name: STRIPE_METER_EVENT_NAME,
    payload: {
      stripe_customer_id: customerId,
      value: value.toString(),
    },
    ...(idempotencyKey && {identifier: idempotencyKey}),
  });

  signale.debug(`[METER-WORKER] Recorded ${value} email(s) for customer ${customerId}`);
}

export function createMeterWorker(): Worker {
  const worker = new Worker<MeterEventJobData>(
    meterQueue.name,
    job => processMeterJob(job.data),
    {
      connection: meterQueue.opts.connection,
      concurrency: 5,
      limiter: {
        max: 50,
        duration: 1000, // Stay well within Stripe's rate limits
      },
    },
  );

  worker.on('failed', (job, error) => {
    signale.error(`[METER-WORKER] Job ${job?.id} failed (attempt ${job?.attemptsMade}):`, error);
  });

  worker.on('error', error => {
    signale.error('[METER-WORKER] Worker error:', error);
  });

  return worker;
}

import {Queue} from 'bullmq';
import type {RedisOptions} from 'ioredis';

import {REDIS_URL} from '../app/constants.js';
import {getBullMqRedisOptions} from '../database/redis.js';
import type {QueueAdapter, QueueEnqueueOptions, QueuedJob, RealTimeQueueJobData, RealTimeQueueName} from './types.js';

const connection: RedisOptions = {
  maxRetriesPerRequest: null,
  enableReadyCheck: false,
  ...getBullMqRedisOptions(REDIS_URL),
};

const options = (attempts: number, delay: number, removeOnComplete: number, removeOnFail: number) => ({
  connection,
  defaultJobOptions: {
    attempts,
    backoff: {type: 'exponential' as const, delay},
    removeOnComplete,
    removeOnFail,
  },
});

const queues: Record<RealTimeQueueName, Queue> = {
  email: new Queue('email', options(3, 2_000, 1_000, 5_000)),
  campaign: new Queue('campaign', options(3, 5_000, 100, 500)),
  scheduled: new Queue('scheduled', options(3, 10_000, 100, 500)),
  workflow: new Queue('workflow', options(3, 2_000, 1_000, 5_000)),
  import: new Queue('import', options(2, 5_000, 50, 100)),
  'bulk-contact-actions': new Queue('bulk-contact-actions', options(2, 5_000, 50, 100)),
  meter: new Queue('meter', options(10, 5_000, 5_000, 10_000)),
};

const jobNames: Record<RealTimeQueueName, string> = {
  email: 'send-email',
  campaign: 'process-batch',
  scheduled: 'send-scheduled-campaign',
  workflow: 'process-step',
  import: 'import-contacts',
  'bulk-contact-actions': 'bulk-contact-action',
  meter: 'record-meter-event',
};

export const bullmqAdapter: QueueAdapter = {
  async enqueue<T extends RealTimeQueueJobData>(
    queue: RealTimeQueueName,
    data: T,
    options: QueueEnqueueOptions = {},
  ): Promise<QueuedJob<T>> {
    const job = await queues[queue].add(jobNames[queue], data, {
      delay: options.delayMs,
      jobId: options.jobId,
      priority: options.emailPriority,
    });

    if (!job.id) {
      throw new Error(`BullMQ did not return an id for ${queue} job`);
    }

    return {id: job.id, data};
  },
};

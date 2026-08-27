import {CloudTasksClient} from '@google-cloud/tasks';

import {nextCloudTaskSchedule} from './types.js';
import type {
  CloudTaskEnvelope,
  QueueAdapter,
  QueueEnqueueOptions,
  QueuedJob,
  RealTimeQueueJobData,
  RealTimeQueueName,
} from './types.js';

export interface CloudTasksConfig {
  projectId: string;
  location: string;
  workerUrl: string;
  audience: string;
  serviceAccountEmail: string;
}

interface CloudTasksClientLike {
  queuePath(project: string, location: string, queue: string): string;
  createTask(request: Record<string, unknown>): Promise<unknown[]>;
}

function isAlreadyExists(error: unknown): boolean {
  const code = (error as {code?: number | string})?.code;
  return code === 6 || code === 'ALREADY_EXISTS';
}

export function createCloudTasksAdapter(
  config: CloudTasksConfig,
  client: CloudTasksClientLike = new CloudTasksClient(),
  createJobId: () => string = () => crypto.randomUUID(),
): QueueAdapter {
  return {
    async enqueue<T extends RealTimeQueueJobData>(
      queue: RealTimeQueueName,
      data: T,
      options: QueueEnqueueOptions = {},
    ): Promise<QueuedJob<T>> {
      const jobId = options.jobId ?? createJobId();
      const hop = options.cloudTaskHop ?? 0;
      const {scheduleAt, notBefore} = nextCloudTaskSchedule(options.delayMs ?? 0);
      const persistsPayload = queue === 'import' || queue === 'bulk-contact-actions';
      if (persistsPayload && hop === 0) {
        const {progressStore} = await import('./progress-store.js');
        await progressStore.create(jobId, queue, data);
      }
      const payload: CloudTaskEnvelope<T> = {
        jobId,
        queue,
        ...(persistsPayload ? {} : {data}),
        notBefore,
        hop,
      };
      const queueName =
        queue === 'email'
          ? options.emailPriority === 1
            ? 'email-transactional'
            : options.emailPriority === 10
              ? 'email-campaign'
              : 'email-workflow'
          : queue;
      const parent = client.queuePath(config.projectId, config.location, queueName);
      const body = Buffer.from(JSON.stringify(payload)).toString('base64');

      try {
        await client.createTask({
          parent,
          task: {
            name: `${parent}/tasks/${jobId}-hop-${hop}`,
            httpRequest: {
              httpMethod: 'POST',
              url: `${config.workerUrl}/tasks/${queue}`,
              headers: {'Content-Type': 'application/json'},
              body,
              oidcToken: {
                serviceAccountEmail: config.serviceAccountEmail,
                audience: config.audience,
              },
            },
            scheduleTime: {seconds: Math.floor(scheduleAt / 1_000)},
          },
        });
      } catch (error) {
        // Task names are deliberately deterministic. A retry may reach Cloud
        // Tasks after its first create already succeeded, in which case the
        // existing task is the idempotent result we want.
        if (!isAlreadyExists(error)) throw error;
      }

      return {id: jobId, data};
    },
  };
}

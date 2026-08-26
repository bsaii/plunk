import {
  CLOUD_TASKS_AUDIENCE,
  CLOUD_TASKS_LOCATION,
  CLOUD_TASKS_PROJECT_ID,
  CLOUD_TASKS_SERVICE_ACCOUNT_EMAIL,
  CLOUD_TASKS_WORKER_URL,
  REALTIME_QUEUE_BACKEND,
} from '../app/constants.js';
import {bullmqAdapter} from './bullmq-adapter.js';
import {createCloudTasksAdapter} from './cloud-tasks-adapter.js';
import type {QueueAdapter} from './types.js';

let adapter: QueueAdapter | undefined;

export function getQueueAdapter(): QueueAdapter {
  if (adapter) return adapter;

  if (REALTIME_QUEUE_BACKEND === 'bullmq') {
    adapter = bullmqAdapter;
    return adapter;
  }

  const missing = [
    ['CLOUD_TASKS_PROJECT_ID', CLOUD_TASKS_PROJECT_ID],
    ['CLOUD_TASKS_LOCATION', CLOUD_TASKS_LOCATION],
    ['CLOUD_TASKS_WORKER_URL', CLOUD_TASKS_WORKER_URL],
    ['CLOUD_TASKS_AUDIENCE', CLOUD_TASKS_AUDIENCE],
    ['CLOUD_TASKS_SERVICE_ACCOUNT_EMAIL', CLOUD_TASKS_SERVICE_ACCOUNT_EMAIL],
  ].filter(([, value]) => !value);

  if (missing.length > 0) {
    throw new Error(`Cloud Tasks real-time queue backend requires ${missing.map(([key]) => key).join(', ')}`);
  }

  adapter = createCloudTasksAdapter({
    projectId: CLOUD_TASKS_PROJECT_ID,
    location: CLOUD_TASKS_LOCATION,
    workerUrl: CLOUD_TASKS_WORKER_URL,
    audience: CLOUD_TASKS_AUDIENCE,
    serviceAccountEmail: CLOUD_TASKS_SERVICE_ACCOUNT_EMAIL,
  });
  return adapter;
}

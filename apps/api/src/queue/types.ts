import type {
  BulkContactActionJobData,
  CampaignBatchJobData,
  ContactImportJobData,
  MeterEventJobData,
  ScheduledCampaignJobData,
  SendEmailJobData,
  WorkflowStepJobData,
} from '@plunk/types';

export const MAX_CLOUD_TASK_DELAY_MS = 30 * 24 * 60 * 60 * 1000;

export type RealTimeQueueName =
  | 'email'
  | 'campaign'
  | 'scheduled'
  | 'workflow'
  | 'import'
  | 'bulk-contact-actions'
  | 'meter';

export type RealTimeQueueJobData =
  | SendEmailJobData
  | CampaignBatchJobData
  | ScheduledCampaignJobData
  | WorkflowStepJobData
  | ContactImportJobData
  | BulkContactActionJobData
  | MeterEventJobData;

export interface QueuedJob<T = RealTimeQueueJobData> {
  id: string;
  data: T;
}

export interface QueueJobContext {
  updateProgress?: (progress: number) => Promise<void>;
}

export interface QueueEnqueueOptions {
  delayMs?: number;
  jobId?: string;
  emailPriority?: 1 | 5 | 10;
  /**
   * Internal Cloud Tasks rescheduling hop. It is carried in the task envelope
   * so each task in a delay chain has a unique deterministic task name.
   */
  cloudTaskHop?: number;
}

export interface QueueAdapter {
  enqueue<T extends RealTimeQueueJobData>(
    queue: RealTimeQueueName,
    data: T,
    options?: QueueEnqueueOptions,
  ): Promise<QueuedJob<T>>;
  cancel?(jobId: string): Promise<void>;
}

export interface CloudTaskEnvelope<T = RealTimeQueueJobData> {
  jobId: string;
  queue: RealTimeQueueName;
  data?: T;
  notBefore: number;
  hop: number;
}

export function nextCloudTaskSchedule(delayMs: number, now = Date.now()): {scheduleAt: number; notBefore: number} {
  const normalizedDelay = Math.max(delayMs, 0);
  return {
    scheduleAt: now + Math.min(normalizedDelay, MAX_CLOUD_TASK_DELAY_MS),
    notBefore: now + normalizedDelay,
  };
}

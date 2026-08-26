import {redis} from '../database/redis.js';

import type {RealTimeQueueJobData, RealTimeQueueName} from './types.js';

const EXPIRY_SECONDS = 7 * 24 * 60 * 60;

export type QueueJobState = 'queued' | 'active' | 'completed' | 'failed';

export interface StoredQueueJob<T = RealTimeQueueJobData> {
  id: string;
  queue: RealTimeQueueName;
  data: T;
  state: QueueJobState;
  progress: number;
  result?: unknown;
  failedReason?: string;
}

const key = (jobId: string) => `queue-progress:${jobId}`;

async function save(job: StoredQueueJob): Promise<void> {
  await redis.set(key(job.id), JSON.stringify(job), 'EX', EXPIRY_SECONDS);
}

export const progressStore = {
  async create<T extends RealTimeQueueJobData>(id: string, queue: RealTimeQueueName, data: T): Promise<void> {
    await save({id, queue, data, state: 'queued', progress: 0});
  },
  async get<T extends RealTimeQueueJobData>(id: string): Promise<StoredQueueJob<T> | null> {
    const value = await redis.get(key(id));
    return value ? (JSON.parse(value) as StoredQueueJob<T>) : null;
  },
  async markActive(id: string): Promise<void> {
    const job = await this.get(id);
    if (job) await save({...job, state: 'active'});
  },
  async updateProgress(id: string, progress: number): Promise<void> {
    const job = await this.get(id);
    if (job) await save({...job, progress});
  },
  async complete(id: string, result?: unknown): Promise<void> {
    const job = await this.get(id);
    if (job) await save({...job, state: 'completed', progress: 100, result});
  },
  async fail(id: string, error: unknown): Promise<void> {
    const job = await this.get(id);
    if (job) await save({...job, state: 'failed', failedReason: error instanceof Error ? error.message : String(error)});
  },
};

import {describe, expect, it, vi} from 'vitest';

import {createCloudTasksAdapter} from '../cloud-tasks-adapter.js';

describe('CloudTasksAdapter', () => {
  it('uses a 30-day hop while preserving the final execution time', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(0);
    const createTask = vi.fn().mockResolvedValue([{name: 'task-name'}]);
    const adapter = createCloudTasksAdapter(
      {
        projectId: 'project',
        location: 'region',
        workerUrl: 'https://worker.example.com',
        audience: 'https://worker.example.com',
        serviceAccountEmail: 'tasks@example.iam.gserviceaccount.com',
      },
      {queuePath: () => 'queue-path', createTask},
      () => 'job-1',
    );

    await adapter.enqueue('email', {emailId: 'email-1'}, {delayMs: 45 * 24 * 60 * 60 * 1000});

    const request = createTask.mock.calls[0][0];
    const payload = JSON.parse(Buffer.from(request.task.httpRequest.body, 'base64').toString('utf8'));
    expect(request.parent).toBe('queue-path');
    expect(request.task.name).toBe('queue-path/tasks/job-1-hop-0');
    expect(payload).toMatchObject({jobId: 'job-1', queue: 'email', hop: 0, notBefore: 45 * 24 * 60 * 60 * 1000});
    expect(request.task.scheduleTime.seconds).toBe(30 * 24 * 60 * 60);
    vi.useRealTimers();
  });

  it('treats an existing deterministic task as an idempotent enqueue', async () => {
    const createTask = vi.fn().mockRejectedValue({code: 6});
    const adapter = createCloudTasksAdapter(
      {
        projectId: 'project',
        location: 'region',
        workerUrl: 'https://worker.example.com',
        audience: 'https://worker.example.com',
        serviceAccountEmail: 'tasks@example.iam.gserviceaccount.com',
      },
      {queuePath: () => 'queue-path', createTask},
      () => 'job-1',
    );

    await expect(adapter.enqueue('email', {emailId: 'email-1'}, {jobId: 'job-1'})).resolves.toMatchObject({id: 'job-1'});
  });

  it('uses a distinct deterministic name for each long-delay hop', async () => {
    const createTask = vi.fn().mockResolvedValue([{name: 'task-name'}]);
    const adapter = createCloudTasksAdapter(
      {
        projectId: 'project',
        location: 'region',
        workerUrl: 'https://worker.example.com',
        audience: 'https://worker.example.com',
        serviceAccountEmail: 'tasks@example.iam.gserviceaccount.com',
      },
      {queuePath: () => 'queue-path', createTask},
      () => 'job-1',
    );

    await adapter.enqueue('email', {emailId: 'email-1'}, {jobId: 'job-1'});
    await adapter.enqueue('email', {emailId: 'email-1'}, {jobId: 'job-1', cloudTaskHop: 1});

    expect(createTask.mock.calls[0][0].task.name).toBe('queue-path/tasks/job-1-hop-0');
    expect(createTask.mock.calls[1][0].task.name).toBe('queue-path/tasks/job-1-hop-1');
  });
});

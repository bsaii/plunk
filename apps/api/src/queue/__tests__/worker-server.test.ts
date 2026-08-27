import request from 'supertest';
import {describe, expect, it} from 'vitest';

describe('Cloud Tasks worker server', () => {
  it('rejects a task request without a bearer token', async () => {
    process.env.CLOUD_TASKS_AUDIENCE = 'https://worker.example.com';
    process.env.CLOUD_TASKS_SERVICE_ACCOUNT_EMAIL = 'tasks@example.iam.gserviceaccount.com';
    process.env.JWT_SECRET = 'test';
    process.env.API_URI = 'http://api.test';
    process.env.DASHBOARD_URI = 'http://app.test';
    process.env.LANDING_URI = 'http://www.test';
    process.env.WIKI_URI = 'http://wiki.test';
    process.env.REDIS_URL = 'redis://127.0.0.1:6379';
    process.env.DATABASE_URL = 'postgresql://postgres:postgres@127.0.0.1:5432/postgres';
    process.env.DIRECT_DATABASE_URL = process.env.DATABASE_URL;
    process.env.AWS_SES_REGION = 'us-east-1';
    process.env.AWS_SES_ACCESS_KEY_ID = 'test';
    process.env.AWS_SES_SECRET_ACCESS_KEY = 'test';

    const {createWorkerServer} = await import('../../jobs/worker-server.js');
    const response = await request(createWorkerServer(async () => undefined)).post('/tasks/email').send({jobId: 'job-1'});

    expect(response.status).toBe(401);
  });

  it('rejects a valid-audience token from another service account', async () => {
    const {createGoogleTokenVerifier} = await import('../../jobs/worker-server.js');
    const verifyToken = createGoogleTokenVerifier({
      verifyIdToken: async () => ({getPayload: () => ({email: 'other@example.iam.gserviceaccount.com'})}),
    } as never);

    await expect(verifyToken('valid-token')).rejects.toThrow('configured service account');
  });
});

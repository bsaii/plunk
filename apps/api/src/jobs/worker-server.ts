import {OAuth2Client} from 'google-auth-library';
import express from 'express';
import signale from 'signale';

import {CLOUD_TASKS_AUDIENCE, CLOUD_TASKS_SERVICE_ACCOUNT_EMAIL, PORT} from '../app/constants.js';
import {getQueueAdapter} from '../queue/adapter.js';
import {progressStore} from '../queue/progress-store.js';
import type {CloudTaskEnvelope, RealTimeQueueJobData, RealTimeQueueName} from '../queue/types.js';
import {processBulkContactJob} from './bulk-contact-processor.js';
import {processCampaignJob} from './campaign-processor.js';
import {processEmailJob} from './email-processor.js';
import {processImportJob} from './import-processor.js';
import {processMeterJob} from './meter-processor.js';
import {processScheduledCampaignJob} from './scheduled-processor.js';
import {processWorkflowJob} from './workflow-processor-queue.js';

type VerifyToken = (token: string) => Promise<void>;

const storesProgress = (queue: RealTimeQueueName): boolean => queue === 'import' || queue === 'bulk-contact-actions';

export function createGoogleTokenVerifier(client: Pick<OAuth2Client, 'verifyIdToken'> = new OAuth2Client()): VerifyToken {
  return async token => {
    const ticket = await client.verifyIdToken({idToken: token, audience: CLOUD_TASKS_AUDIENCE});
    if (ticket.getPayload()?.email !== CLOUD_TASKS_SERVICE_ACCOUNT_EMAIL) {
      throw new Error('Cloud Tasks token was not issued to the configured service account');
    }
  };
}

async function processEnvelope(envelope: CloudTaskEnvelope): Promise<void> {
  const tracksProgress = storesProgress(envelope.queue);
  const stored = !envelope.data && tracksProgress ? await progressStore.get(envelope.jobId) : null;
  const data = envelope.data ?? stored?.data;
  if (!data) throw new Error(`Task ${envelope.jobId} has no payload`);

  if (envelope.notBefore > Date.now()) {
    await getQueueAdapter().enqueue(envelope.queue, data, {
      delayMs: envelope.notBefore - Date.now(),
      jobId: envelope.jobId,
      cloudTaskHop: envelope.hop + 1,
    });
    return;
  }

  if (tracksProgress) await progressStore.markActive(envelope.jobId);
  const context = {updateProgress: (progress: number) => progressStore.updateProgress(envelope.jobId, progress)};
  let result: unknown;

  switch (envelope.queue) {
    case 'email':
      result = await processEmailJob(data as Extract<RealTimeQueueJobData, {emailId: string}>);
      break;
    case 'campaign':
      result = await processCampaignJob(data as Extract<RealTimeQueueJobData, {campaignId: string; batchNumber: number}>);
      break;
    case 'scheduled':
      result = await processScheduledCampaignJob(data as Extract<RealTimeQueueJobData, {campaignId: string}>);
      break;
    case 'workflow':
      result = await processWorkflowJob(data as Extract<RealTimeQueueJobData, {executionId: string}>);
      break;
    case 'import':
      result = await processImportJob(data as Extract<RealTimeQueueJobData, {csvData: string}>, context);
      break;
    case 'bulk-contact-actions':
      result = await processBulkContactJob(data as Extract<RealTimeQueueJobData, {selector: unknown}>, context);
      break;
    case 'meter':
      result = await processMeterJob(data as Extract<RealTimeQueueJobData, {customerId: string}>);
      break;
  }

  if (tracksProgress) await progressStore.complete(envelope.jobId, result);
}

export function createWorkerServer(verifyToken: VerifyToken = createGoogleTokenVerifier()) {
  const app = express();
  app.use(express.json({limit: '1mb'}));
  app.post('/tasks/:queue', async (req, res) => {
    const token = req.get('authorization')?.match(/^Bearer (.+)$/i)?.[1];
    if (!token) return res.status(401).json({error: 'Missing bearer token'});

    try {
      await verifyToken(token);
    } catch {
      return res.status(401).json({error: 'Invalid bearer token'});
    }

    const envelope = req.body as CloudTaskEnvelope;
    if (!envelope?.jobId || envelope.queue !== req.params.queue || typeof envelope.hop !== 'number') {
      return res.status(400).json({error: 'Invalid task envelope'});
    }

    try {
      await processEnvelope(envelope);
      return res.sendStatus(204);
    } catch (error) {
      if (storesProgress(envelope.queue)) await progressStore.fail(envelope.jobId, error);
      signale.error(`[WORKER-SERVER] Task ${envelope.jobId} failed:`, error);
      return res.status(500).json({error: 'Task processing failed'});
    }
  });
  return app;
}

if (process.argv[1]?.endsWith('worker-server.js')) {
  createWorkerServer().listen(PORT, () => signale.info(`[WORKER-SERVER] Listening on ${PORT}`));
}

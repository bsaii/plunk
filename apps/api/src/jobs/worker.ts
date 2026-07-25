/**
 * Unified Queue Worker
 * Starts all queue processors (email, campaign, scheduled, workflow, import, segment-count, domain-verification)
 *
 * This should be run as a separate process in production:
 * node dist/jobs/worker.js
 */

import {createServer} from 'node:http';

import {Worker} from 'bullmq';
import signale from 'signale';

import {createApiRequestCleanupWorker} from './api-request-cleanup-processor.js';
import {createBulkContactWorker} from './bulk-contact-processor.js';
import {createCampaignWorker} from './campaign-processor.js';
import {createDomainVerificationWorker} from './domain-verification-processor.js';
import {createEmailWorker} from './email-processor.js';
import {createImportWorker} from './import-processor.js';
import {createMeterWorker} from './meter-processor.js';
import {createScheduledCampaignWorker} from './scheduled-processor.js';
import {createSegmentCountWorker} from './segment-count-processor.js';
import {createWorkflowWorker} from './workflow-processor-queue.js';

const workers: {name: string; worker: Worker}[] = [];

let ready = false;

/**
 * Health endpoint for container liveness probes.
 *
 * The worker serves no traffic — it is deployed as a Cloud Run worker pool,
 * which does not require a listener at all — so this exists purely so the
 * platform (and the compose/self-host healthcheck) can distinguish a running
 * instance from a wedged one.
 *
 * Port resolution: WORKER_HEALTH_PORT wins, then PORT (injected by the platform,
 * so deploying this as a plain Cloud Run service also works with no extra
 * configuration), then 8081. The 8081 fallback keeps the all-in-one image —
 * where the API and the worker share a container — off the API's 8080.
 */
const healthPort = Number(process.env.WORKER_HEALTH_PORT ?? process.env.PORT ?? 8081);

/**
 * Whether the queues are actually reachable.
 *
 * Checking only that startWorkers() finished is not enough: BullMQ constructs
 * its workers happily while ioredis reconnects in the background, so a worker
 * that has never reached Redis — and is therefore consuming nothing — still
 * looks fully started. Reporting the connection state is the difference between
 * a probe that detects a wedged instance and one that always says "ok".
 */
async function queuesConnected() {
  const first = workers[0];

  if (!first) {
    return false;
  }

  try {
    // `worker.client` does not settle while Redis is unreachable, so awaiting it
    // bare would hang the probe rather than fail it — which reads as a timeout to
    // the caller instead of an unhealthy instance. Bound it.
    const timeout = new Promise<null>(resolve => {
      setTimeout(() => resolve(null), 500).unref();
    });

    const client = await Promise.race([first.worker.client, timeout]);

    return client !== null && client.status === 'ready';
  } catch {
    return false;
  }
}

const healthServer = createServer((req, res) => {
  if (req.url !== '/health' && req.url !== '/') {
    res.writeHead(404).end();
    return;
  }

  void (async () => {
    const connected = ready && (await queuesConnected());

    const body = JSON.stringify({
      status: connected ? 'ok' : ready ? 'disconnected' : 'starting',
      workers: workers.map(({name}) => name),
    });

    res.writeHead(connected ? 200 : 503, {'content-type': 'application/json'}).end(body);
  })();
});

// A port clash must not take down job processing: the all-in-one image runs this
// alongside the API under pm2, and losing the queue consumers is far worse than
// losing the probe.
healthServer.on('error', error => {
  signale.warn(`[WORKER] Health server unavailable on port ${healthPort}:`, error);
});

async function startWorkers() {
  signale.info('[WORKER] Starting queue workers...');

  try {
    // Start email worker
    const emailWorker = await createEmailWorker();
    workers.push({name: 'email', worker: emailWorker});
    signale.success('[WORKER] Email worker started');

    // Start campaign worker
    const campaignWorker = createCampaignWorker();
    workers.push({name: 'campaign', worker: campaignWorker});
    signale.success('[WORKER] Campaign worker started');

    // Start scheduled campaign worker
    const scheduledWorker = createScheduledCampaignWorker();
    workers.push({name: 'scheduled', worker: scheduledWorker});
    signale.success('[WORKER] Scheduled campaign worker started');

    // Start workflow worker
    const workflowWorker = createWorkflowWorker();
    workers.push({name: 'workflow', worker: workflowWorker});
    signale.success('[WORKER] Workflow worker started');

    // Start import worker
    const importWorker = createImportWorker();
    workers.push({name: 'import', worker: importWorker});
    signale.success('[WORKER] Import worker started');

    // Start bulk contact action worker
    const bulkContactWorker = createBulkContactWorker();
    workers.push({name: 'bulk-contact-actions', worker: bulkContactWorker});
    signale.success('[WORKER] Bulk contact action worker started');

    // Start segment count worker
    const segmentCountWorker = createSegmentCountWorker();
    workers.push({name: 'segment-count', worker: segmentCountWorker});
    signale.success('[WORKER] Segment count worker started');

    // Start domain verification worker
    const domainVerificationWorker = createDomainVerificationWorker();
    workers.push({name: 'domain-verification', worker: domainVerificationWorker});
    signale.success('[WORKER] Domain verification worker started');

    // Start API request cleanup worker
    const apiRequestCleanupWorker = createApiRequestCleanupWorker();
    workers.push({name: 'api-request-cleanup', worker: apiRequestCleanupWorker});
    signale.success('[WORKER] API request cleanup worker started');

    // Start meter worker
    const meterWorker = createMeterWorker();
    workers.push({name: 'meter', worker: meterWorker});
    signale.success('[WORKER] Meter worker started');

    ready = true;
    signale.success('[WORKER] All workers started successfully');
  } catch (error) {
    signale.error('[WORKER] Failed to start workers:', error);
    process.exit(1);
  }
}

async function stopWorkers() {
  signale.info('[WORKER] Stopping workers...');

  ready = false;
  healthServer.close();

  for (const {name, worker} of workers) {
    try {
      await worker.close();
      signale.info(`[WORKER] ${name} worker stopped`);
    } catch (error) {
      signale.error(`[WORKER] Error stopping ${name} worker:`, error);
    }
  }

  signale.success('[WORKER] All workers stopped');
  process.exit(0);
}

// Handle graceful shutdown
process.on('SIGINT', () => {
  signale.info('[WORKER] Received SIGINT, shutting down gracefully...');
  void stopWorkers();
});

process.on('SIGTERM', () => {
  signale.info('[WORKER] Received SIGTERM, shutting down gracefully...');
  void stopWorkers();
});

process.on('uncaughtException', error => {
  signale.error('[WORKER] Uncaught exception:', error);
  void stopWorkers();
});

process.on('unhandledRejection', (reason, promise) => {
  signale.error('[WORKER] Unhandled rejection at:', promise, 'reason:', reason);
  void stopWorkers();
});

// Bind the health port before the queues connect, so a platform probing for
// liveness sees "starting" rather than a refused connection.
healthServer.listen(healthPort, '0.0.0.0', () => {
  signale.info(`[WORKER] Health endpoint on :${healthPort}/health`);
});

// Start workers
void startWorkers();

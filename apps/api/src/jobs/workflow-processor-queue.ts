/**
 * Background Job: Workflow Queue Processor
 * Processes workflow steps from the queue (for delayed steps)
 */

import type {WorkflowStepJobData} from '@plunk/types';
import {Worker} from 'bullmq';
import signale from 'signale';

import {workflowQueue} from '../services/QueueService.js';
import {WorkflowExecutionService} from '../services/WorkflowExecutionService.js';

export function createWorkflowWorker() {
  const worker = new Worker<WorkflowStepJobData>(
    workflowQueue.name,
    job => processWorkflowJob(job.data),
    {
      connection: workflowQueue.opts.connection,
      concurrency: 10, // Process up to 10 workflow steps concurrently
    },
  );

  worker.on('completed', job => {
    signale.info(`[WORKFLOW-PROCESSOR] Job ${job.id} completed`);
  });

  worker.on('failed', (job, err) => {
    signale.error(`[WORKFLOW-PROCESSOR] Job ${job?.id} failed:`, err.message);
  });

  worker.on('error', err => {
    signale.error('[WORKFLOW-PROCESSOR] Worker error:', err);
  });

  return worker;
}

export async function processWorkflowJob(data: WorkflowStepJobData): Promise<void> {
  const {executionId, stepId, type, stepExecutionId} = data;
  if (type === 'timeout') {
    if (!stepExecutionId) throw new Error('stepExecutionId is required for timeout jobs');
    await WorkflowExecutionService.processTimeout(executionId, stepId, stepExecutionId);
    return;
  }
  await WorkflowExecutionService.processStepExecution(executionId, stepId);
}

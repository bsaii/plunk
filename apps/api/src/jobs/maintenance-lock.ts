import {randomUUID} from 'node:crypto';
import type {Redis} from 'ioredis';
import signale from 'signale';

// The process must stop before the lease can expire and admit another sweep.
// Cloud Run should also enforce a 600s task timeout (see the rollout guide).
export const MAINTENANCE_DEADLINE_MS = 9 * 60 * 1000;
export const MAINTENANCE_LEASE_MS = 10 * 60 * 1000;

const RELEASE_LOCK = `
  if redis.call('get', KEYS[1]) == ARGV[1] then
    return redis.call('del', KEYS[1])
  end
  return 0
`;

/**
 * Cloud Run executions are independent: BullMQ's concurrency limit does not
 * serialize them. A lease per task skips overlapping executions while allowing
 * different maintenance tasks to run concurrently. Use a shared Redis database
 * for all executions of this deployment, isolated from other environments.
 */
export async function runWithMaintenanceLock(
  redis: Pick<Redis, 'set' | 'eval'>,
  task: string,
  run: () => Promise<unknown>,
): Promise<'completed' | 'skipped'> {
  const key = `plunk:maintenance:lock:${task}`;
  const owner = randomUUID();
  const startedAt = Date.now();
  let acquired = false;

  // A rejected Promise cannot cancel in-flight DB queries or side effects.
  // Terminate this dedicated CLI process instead, leaving the lease to expire.
  const deadline = setTimeout(() => {
    signale.error(`[MAINTENANCE-RUNNER] Task "${task}" exceeded its 9-minute deadline; exiting`);
    process.exit(1);
  }, MAINTENANCE_DEADLINE_MS);

  try {
    acquired = (await redis.set(key, owner, 'PX', MAINTENANCE_LEASE_MS, 'NX')) === 'OK';
    if (!acquired) {
      signale.info(`[MAINTENANCE-RUNNER] Skipping task "${task}": another execution holds the lease`);
      return 'skipped';
    }

    signale.info(`[MAINTENANCE-RUNNER] Running task "${task}"...`);
    await run();
    signale.success(`[MAINTENANCE-RUNNER] Task "${task}" completed in ${Date.now() - startedAt}ms`);
    return 'completed';
  } finally {
    try {
      if (acquired) {
        // Never delete a replacement lease belonging to another execution.
        await redis.eval(RELEASE_LOCK, 1, key, owner);
      }
    } catch (error) {
      // Do not replay successful work just because lease cleanup failed.
      // The TTL recovers the lock after crashes or Redis failures.
      signale.warn(`[MAINTENANCE-RUNNER] Could not release task "${task}" lease; it will expire`, error);
    } finally {
      clearTimeout(deadline);
    }
  }
}

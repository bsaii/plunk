import {afterEach, beforeEach, describe, expect, it, vi} from 'vitest';

import {MAINTENANCE_DEADLINE_MS, MAINTENANCE_LEASE_MS, runWithMaintenanceLock} from '../maintenance-lock.js';

vi.mock('signale', () => ({default: {info: vi.fn(), success: vi.fn(), warn: vi.fn(), error: vi.fn()}}));

describe('maintenance execution lease', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => {
    vi.clearAllTimers();
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  function client() {
    return {set: vi.fn().mockResolvedValue('OK'), eval: vi.fn().mockResolvedValue(1)};
  }

  it('releases only its own lease after successful work', async () => {
    const redis = client();
    const run = vi.fn().mockResolvedValue(undefined);

    await expect(runWithMaintenanceLock(redis, 'segment-count', run)).resolves.toBe('completed');

    expect(run).toHaveBeenCalledOnce();
    expect(redis.set).toHaveBeenCalledWith(
      'plunk:maintenance:lock:segment-count',
      expect.any(String),
      'PX',
      MAINTENANCE_LEASE_MS,
      'NX',
    );
    expect(redis.eval).toHaveBeenCalledWith(
      expect.stringContaining("redis.call('get', KEYS[1]) == ARGV[1]"),
      1,
      'plunk:maintenance:lock:segment-count',
      redis.set.mock.calls[0]![1],
    );
    expect(vi.getTimerCount()).toBe(0);
  });

  it('skips an overlapping execution without running work or deleting the active lease', async () => {
    const redis = client();
    redis.set.mockResolvedValue(null);
    const run = vi.fn();

    await expect(runWithMaintenanceLock(redis, 'segment-count', run)).resolves.toBe('skipped');
    expect(run).not.toHaveBeenCalled();
    expect(redis.eval).not.toHaveBeenCalled();
    expect(vi.getTimerCount()).toBe(0);
  });

  it('fails closed when Redis cannot grant a lease', async () => {
    const redis = client();
    redis.set.mockRejectedValue(new Error('Redis unavailable'));
    const run = vi.fn();

    await expect(runWithMaintenanceLock(redis, 'segment-count', run)).rejects.toThrow('Redis unavailable');
    expect(run).not.toHaveBeenCalled();
    expect(redis.eval).not.toHaveBeenCalled();
    expect(vi.getTimerCount()).toBe(0);
  });

  it('releases on failure and preserves the task error even if release also fails', async () => {
    const redis = client();
    redis.eval.mockRejectedValue(new Error('Redis disconnected'));

    await expect(
      runWithMaintenanceLock(redis, 'segment-count', async () => {
        throw new Error('database unavailable');
      }),
    ).rejects.toThrow('database unavailable');
    expect(redis.eval).toHaveBeenCalledOnce();
    expect(vi.getTimerCount()).toBe(0);
  });

  it('does not retry completed work just because releasing its lease failed', async () => {
    const redis = client();
    redis.eval.mockRejectedValue(new Error('Redis disconnected'));
    await expect(runWithMaintenanceLock(redis, 'segment-count', async () => {})).resolves.toBe('completed');
  });

  it('uses independent keys for different tasks and unique owners for successive runs', async () => {
    const redis = client();
    await runWithMaintenanceLock(redis, 'segment-count', async () => {});
    await runWithMaintenanceLock(redis, 'domain-verification', async () => {});
    await runWithMaintenanceLock(redis, 'segment-count', async () => {});
    expect(redis.set.mock.calls[0]![0]).not.toBe(redis.set.mock.calls[1]![0]);
    expect(redis.set.mock.calls[0]![1]).not.toBe(redis.set.mock.calls[2]![1]);
  });

  it('terminates stalled work before the lease expires instead of releasing it while work continues', async () => {
    const redis = client();
    let finish!: () => void;
    const run = vi.fn(
      () =>
        new Promise<void>(resolve => {
          finish = resolve;
        }),
    );
    const exit = vi.spyOn(process, 'exit').mockImplementation(() => {
      throw new Error('process exited');
    });
    const execution = runWithMaintenanceLock(redis, 'segment-count', run);
    await vi.advanceTimersByTimeAsync(0);

    expect(MAINTENANCE_DEADLINE_MS).toBeLessThan(MAINTENANCE_LEASE_MS);
    expect(() => vi.advanceTimersByTime(MAINTENANCE_DEADLINE_MS)).toThrow('process exited');
    expect(exit).toHaveBeenCalledWith(1);
    expect(redis.eval).not.toHaveBeenCalled();

    // Only settle the promise to clean up this test; the real process is dead.
    finish();
    await execution;
  });
});

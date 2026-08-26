import {describe, expect, it} from 'vitest';

import {MAX_CLOUD_TASK_DELAY_MS, nextCloudTaskSchedule} from '../types.js';

describe('nextCloudTaskSchedule', () => {
  it('caps a 45-day delay at the Cloud Tasks 30-day horizon', () => {
    const fortyFiveDays = 45 * 24 * 60 * 60 * 1000;

    expect(nextCloudTaskSchedule(fortyFiveDays, 0)).toEqual({
      scheduleAt: MAX_CLOUD_TASK_DELAY_MS,
      notBefore: fortyFiveDays,
    });
  });

  it('runs an overdue task immediately', () => {
    expect(nextCloudTaskSchedule(-1_000, 10_000)).toEqual({
      scheduleAt: 10_000,
      notBefore: 10_000,
    });
  });
});

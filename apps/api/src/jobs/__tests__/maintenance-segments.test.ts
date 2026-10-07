import {beforeEach, describe, expect, it, vi} from 'vitest';

const mocks = vi.hoisted(() => ({
  prisma: {
    project: {findMany: vi.fn()},
    segment: {findMany: vi.fn(), update: vi.fn()},
    segmentMembership: {count: vi.fn()},
    contact: {count: vi.fn()},
  },
  notify: vi.fn(),
}));

vi.mock('../../database/prisma.js', () => ({prisma: mocks.prisma}));
vi.mock('../../services/QueueService.js', () => ({segmentCountQueue: {name: 'segment-count'}}));
vi.mock('../../services/NtfyService.js', () => ({NtfyService: {notifySegmentMembershipBundled: mocks.notify}}));
vi.mock('../../services/ContactService.js', () => ({ContactService: {}}));
vi.mock('../../services/EventService.js', () => ({EventService: {}}));
vi.mock('../../exceptions/index.js', () => ({HttpException: class extends Error {}}));
vi.mock('@plunk/db', () => ({Prisma: {}}));
vi.mock('bullmq', () => ({Worker: class {}}));
vi.mock('signale', () => ({default: {info: vi.fn(), success: vi.fn(), error: vi.fn()}}));

import {SegmentService} from '../../services/SegmentService.js';
import {runSegmentCountJob} from '../segment-count-processor.js';

describe('maintenance segment sweep', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    vi.resetAllMocks();
    mocks.prisma.project.findMany.mockResolvedValue([{id: 'project', name: 'Project'}]);
    mocks.prisma.segment.update.mockResolvedValue({});
    mocks.prisma.segmentMembership.count.mockResolvedValue(3);
    mocks.prisma.contact.count.mockResolvedValue(7);
    vi.spyOn(SegmentService, 'buildWhereClause').mockResolvedValue({projectId: 'project'});
  });

  it('computes tracked membership once and counts only untracked segments in a mixed project', async () => {
    const segments = [
      {id: 'tracked', name: 'Tracked', trackMembership: true, type: 'DYNAMIC', condition: {}},
      {id: 'dynamic', name: 'Dynamic', trackMembership: false, type: 'DYNAMIC', condition: {}},
      {id: 'static', name: 'Static', trackMembership: false, type: 'STATIC', condition: {}},
    ];
    mocks.prisma.segment.findMany.mockImplementation(async ({where}) =>
      segments.filter(s => where.trackMembership === undefined || s.trackMembership === where.trackMembership),
    );
    const compute = vi.spyOn(SegmentService, 'computeMembership').mockResolvedValue({added: 2, removed: 1, total: 8});

    await runSegmentCountJob();

    expect(mocks.prisma.project.findMany).toHaveBeenCalledWith({
      where: {disabled: false, segments: {some: {}}},
      select: {id: true, name: true},
    });
    expect(compute).toHaveBeenCalledExactlyOnceWith('project', 'tracked');
    expect(mocks.prisma.contact.count).toHaveBeenCalledOnce();
    expect(mocks.prisma.segmentMembership.count).toHaveBeenCalledExactlyOnceWith({
      where: {segmentId: 'static', exitedAt: null},
    });
    expect(mocks.prisma.segment.update.mock.calls.map(([arg]) => arg.where.id).sort()).toEqual(['dynamic', 'static']);
    expect(mocks.notify).toHaveBeenCalledWith('Project', 'project', 1, 2, 1);
  });

  it('does not run the count-only pass for a tracked-only project', async () => {
    mocks.prisma.segment.findMany.mockResolvedValue([{id: 'tracked', trackMembership: true}]);
    vi.spyOn(SegmentService, 'computeMembership').mockResolvedValue({added: 0, removed: 0, total: 8});
    const refresh = vi.spyOn(SegmentService, 'refreshAllMemberCounts');

    await runSegmentCountJob('project');

    expect(refresh).not.toHaveBeenCalled();
    expect(mocks.prisma.project.findMany).not.toHaveBeenCalled();
  });

  it('does no segment work when no eligible projects exist', async () => {
    mocks.prisma.project.findMany.mockResolvedValue([]);
    await runSegmentCountJob();
    expect(mocks.prisma.segment.findMany).not.toHaveBeenCalled();
  });

  it('preserves all-segment count refreshes for callers that do not request the optimization', async () => {
    mocks.prisma.segment.findMany.mockResolvedValue([{id: 'tracked', type: 'STATIC'}]);
    await SegmentService.refreshAllMemberCounts('project');
    expect(mocks.prisma.segment.findMany).toHaveBeenCalledWith({
      where: {projectId: 'project'},
      select: {id: true, type: true, condition: true},
    });
    expect(mocks.prisma.segment.update).toHaveBeenCalledWith({where: {id: 'tracked'}, data: {memberCount: 3}});
  });
});

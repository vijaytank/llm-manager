import { describe, it, expect } from 'vitest';
import { buildHealthLogEntry } from '../TopBar';

describe('buildHealthLogEntry', () => {
  it('formats a successful health report', () => {
    const entry = buildHealthLogEntry({ passedCount: 4, totalCount: 5 });

    expect(entry).toEqual({
      level: 'INFO',
      message: 'Health check completed: 4/5 checks passed',
    });
  });

  it('formats an error without crashing', () => {
    const entry = buildHealthLogEntry(undefined, { message: 'boom' });

    expect(entry).toEqual({
      level: 'ERROR',
      message: 'Health check error: boom',
    });
  });
});

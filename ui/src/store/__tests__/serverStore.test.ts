import { describe, it, expect, beforeEach } from 'vitest';
import { useServerStore } from '../serverStore';

describe('serverStore', () => {
  beforeEach(() => {
    useServerStore.setState({
      status: 'stopped',
      port: 8080,
      logs: [],
    });
  });

  it('updates status and port', () => {
    useServerStore.getState().setStatus('running');
    useServerStore.getState().setPort(8081);

    expect(useServerStore.getState().status).toBe('running');
    expect(useServerStore.getState().port).toBe(8081);
  });

  it('appends log entries up to buffer limit', () => {
    useServerStore.getState().addLog({
      timestamp: '12:00:00',
      level: 'INFO',
      message: 'Test log line',
    });

    const logs = useServerStore.getState().logs;
    expect(logs.length).toBe(1);
    expect(logs[0].message).toBe('Test log line');
  });
});

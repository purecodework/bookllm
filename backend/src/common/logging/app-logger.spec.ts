import { logInfo, logWarn } from './app-logger';

describe('app-logger', () => {
  const originalLogFormat = process.env.LOG_FORMAT;
  const originalLogLevel = process.env.LOG_LEVEL;
  const originalNodeEnv = process.env.NODE_ENV;

  afterEach(() => {
    process.env.LOG_FORMAT = originalLogFormat;
    process.env.LOG_LEVEL = originalLogLevel;
    process.env.NODE_ENV = originalNodeEnv;
    jest.restoreAllMocks();
  });

  it('redacts sensitive fields and tokens in JSON mode', () => {
    process.env.LOG_FORMAT = 'json';
    process.env.LOG_LEVEL = 'debug';

    const writeSpy = jest.spyOn(process.stdout, 'write').mockImplementation(() => true);

    logInfo('test_log', {
      apiKey: 'secret-key',
      authorization: 'Bearer abcdefg',
      details: 'Invalid key sk-very-secret',
      chunkText: 'x'.repeat(240),
      tokensPerSecond: 12.5,
      nested: { token: '123', normal: 'ok' },
    });

    expect(writeSpy).toHaveBeenCalledTimes(1);
    const [line] = writeSpy.mock.calls[0];
    const payload = JSON.parse(String(line)) as Record<string, unknown>;

    expect(payload.level).toBe('info');
    expect(payload.apiKey).toBe('[REDACTED]');
    expect(payload.authorization).toBe('[REDACTED]');
    expect(payload.details).toBe('Invalid key sk-***');
    expect(payload.chunkText).toEqual(
      expect.objectContaining({
        length: 240,
      }),
    );
    expect(payload.tokensPerSecond).toBe(12.5);
    expect(payload.nested).toEqual(
      expect.objectContaining({
        token: '[REDACTED]',
        normal: 'ok',
      }),
    );
  });

  it('respects LOG_LEVEL filtering', () => {
    process.env.LOG_FORMAT = 'text';
    process.env.LOG_LEVEL = 'warn';

    const stdoutSpy = jest.spyOn(process.stdout, 'write').mockImplementation(() => true);
    const stderrSpy = jest.spyOn(process.stderr, 'write').mockImplementation(() => true);

    logInfo('info_log_should_be_filtered');
    logWarn('warn_log_should_pass');

    expect(stdoutSpy).toHaveBeenCalledTimes(1);
    expect(String(stdoutSpy.mock.calls[0][0])).toContain('WARN warn_log_should_pass');
    expect(stderrSpy).not.toHaveBeenCalled();
  });
});

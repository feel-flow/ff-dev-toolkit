/**
 * Transport-failure tests against the built bundle over raw stdio.
 *
 * These speak JSON-RPC by hand instead of using the SDK client, because the
 * inputs under test — a byte stream too large for the read buffer, and a line
 * that is not valid JSON — cannot be produced by a conforming client.
 *
 * Regression guard: with no transport handlers installed, the SDK dropped these
 * errors. An overflow closed the transport with no log and left the process
 * alive but permanently unable to answer.
 */
import { describe, it, expect, afterEach } from 'vitest';
import { spawn, type ChildProcessWithoutNullStreams } from 'child_process';
import path from 'path';
import url from 'url';
import { STDIO_DEFAULT_MAX_BUFFER_SIZE } from '@modelcontextprotocol/sdk/shared/stdio.js';
import { MAX_CONSECUTIVE_TRANSPORT_ERRORS } from '../src/constants.js';

const __dirname = path.dirname(url.fileURLToPath(import.meta.url));
const DIST = path.resolve(__dirname, '../dist/index.js');
const PROJECT_FIXTURE = path.resolve(__dirname, 'fixtures/project');

/**
 * Any string initializes: the server accepts unknown versions and answers with
 * the SDK's own latest. Pinned only so the request is well-formed.
 */
const PROTOCOL_VERSION = '2025-11-25';
const REPLY_TIMEOUT_MS = 5000;
const EXIT_TIMEOUT_MS = 15000;
/** Enough ~78-byte error lines to overflow the stderr pipe buffer. */
const STDERR_FLOOD_LINES = 5000;
/**
 * When the late-draining tests start reading stderr. Must land after the server
 * hits the fatal trigger (measured ~850 ms for the original 5000-line flood; the
 * interleaved notifications double the writes, moving slower machines toward the
 * early-read case) and before the flush backstop forces the exit (2 s after the
 * trigger). If the read begins before the trigger, the test passes without
 * exercising the flush wait — weaker, but never flaky.
 */
const LATE_DRAIN_DELAY_MS = 1500;

/** A raw stdio session against the server bundle. */
class Session {
  readonly child: ChildProcessWithoutNullStreams;
  stderr = '';
  readonly exited: Promise<number | null>;
  readonly stdinErrors: string[] = [];
  readonly unparsableStdout: string[] = [];
  private pending = '';
  private readonly responses = new Map<number, any>();

  /**
   * @param drainStderr pass false to leave stderr unread, which fills its pipe
   *   buffer and forces the server's error logging to queue.
   */
  constructor({ drainStderr = true }: { drainStderr?: boolean } = {}) {
    this.child = spawn(process.execPath, [DIST], {
      cwd: PROJECT_FIXTURE,
      stdio: ['pipe', 'pipe', 'pipe'],
    }) as ChildProcessWithoutNullStreams;

    if (drainStderr) this.drainStderr();
    this.child.stdout.on('data', (chunk) => {
      this.pending += chunk;
      const lines = this.pending.split('\n');
      this.pending = lines.pop() ?? '';
      for (const line of lines) {
        if (!line.trim()) continue;
        try {
          const msg = JSON.parse(line);
          if (typeof msg.id === 'number') this.responses.set(msg.id, msg);
        } catch {
          // Recorded, not ignored: stdout must carry only JSON-RPC, so a stray
          // console.log is an MCP-fatal condition rather than a timeout.
          this.unparsableStdout.push(line);
        }
      }
    });
    this.child.stdin.on('error', (error: NodeJS.ErrnoException) => {
      // Expected where the server exits mid-write; anything else is recorded so it
      // cannot masquerade as a timeout.
      if (error.code === 'EPIPE' || error.code === 'ERR_STREAM_DESTROYED') return;
      this.stdinErrors.push(`${error.code ?? 'ERR'}: ${error.message}`);
    });
    this.exited = new Promise((resolve) => this.child.on('exit', (code) => resolve(code)));
  }

  drainStderr(): void {
    this.child.stderr.on('data', (chunk) => {
      this.stderr += chunk;
    });
  }

  hasResponse(id: number): boolean {
    return this.responses.has(id);
  }

  write(chunk: string | Buffer): void {
    this.child.stdin.write(chunk);
  }

  send(msg: unknown): void {
    this.write(`${JSON.stringify(msg)}\n`);
  }

  private diagnostics(): string {
    const parts = [`exitCode: ${this.child.exitCode}`, `stderr: ${this.stderr.trim()}`];
    if (this.unparsableStdout.length) parts.push(`non-JSON stdout: ${this.unparsableStdout.join(' | ')}`);
    if (this.stdinErrors.length) parts.push(`stdin errors: ${this.stdinErrors.join(' | ')}`);
    return parts.join(', ');
  }

  async request(id: number, method: string, params?: unknown): Promise<any> {
    this.send({ jsonrpc: '2.0', id, method, ...(params === undefined ? {} : { params }) });
    const deadline = Date.now() + REPLY_TIMEOUT_MS;
    while (Date.now() < deadline) {
      const hit = this.responses.get(id);
      if (hit) return hit;
      if (this.child.exitCode !== null) {
        throw new Error(`server exited before answering ${method}. ${this.diagnostics()}`);
      }
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    throw new Error(`timed out waiting for ${method}. ${this.diagnostics()}`);
  }

  async initialize(): Promise<any> {
    const res = await this.request(1, 'initialize', {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: 'vitest-raw', version: '0.0.0' },
    });
    this.send({ jsonrpc: '2.0', method: 'notifications/initialized' });
    return res;
  }

  /**
   * Wait for exit with a deadline that reports what the server logged. Without
   * this, a server that hangs instead of exiting fails as a bare vitest timeout
   * with no stderr — and "hangs, silently" is the exact bug under test.
   */
  async waitForExit(ms = EXIT_TIMEOUT_MS): Promise<number | null> {
    const timeout = new Promise<never>((_, reject) => {
      setTimeout(
        () => reject(new Error(`server did not exit within ${ms}ms. ${this.diagnostics()}`)),
        ms,
      ).unref();
    });
    return Promise.race([this.exited, timeout]);
  }

  kill(): void {
    if (this.child.exitCode === null) this.child.kill();
  }
}

/** One chunk past the cap with no newline: nothing is consumable, so the buffer grows. */
const overflowChunk = (): Buffer => Buffer.alloc(STDIO_DEFAULT_MAX_BUFFER_SIZE + 1, 0x61);

let session: Session | undefined;

afterEach(() => {
  session?.kill();
  session = undefined;
});

describe('stdio transport failures are reported, and only fatal ones end the process', () => {
  it('logs a read-buffer overflow and exits non-zero rather than lingering unusable', async () => {
    session = new Session();
    await session.initialize();

    session.write(overflowChunk());

    const code = await session.waitForExit();
    // The SDK identifier proves it was the overflow, not some other error.
    expect(session.stderr).toMatch(/transport error: .*ReadBuffer/);
    expect(session.stderr).toContain('transport closed after an error, exiting');
    expect(code).toBe(1);
  }, 20000);

  it('logs a malformed JSON-RPC line but keeps serving requests', async () => {
    session = new Session();
    session.write('this is not json\n');

    const init = await session.initialize();
    expect(init.result.serverInfo.name).toBe('spec-docs');

    // The point of the test: a single bad line must not cost the connection.
    const list = await session.request(2, 'tools/list');
    expect(list.result.tools.length).toBeGreaterThan(0);

    expect(session.stderr).toContain('transport error:');
    expect(session.stderr).not.toContain('exiting');
    expect(session.child.exitCode).toBeNull();
    // Diagnostics belong on stderr; stdout must stay pure JSON-RPC.
    expect(session.unparsableStdout).toEqual([]);
    expect(session.stdinErrors).toEqual([]);
  }, 20000);

  it('does not report a clean close as a failure after a survivable error', async () => {
    // The composition the other tests miss, and the one a future refactor is most
    // likely to break: a recoverable error must not be blamed for a later close.
    session = new Session();
    session.write('this is not json\n');
    await session.initialize();

    session.child.stdin.end();

    const code = await session.waitForExit();
    expect(session.stderr).toContain('transport error:');
    expect(session.stderr).not.toContain('exiting');
    expect(code).toBe(0);
  }, 20000);

  it('keeps the fatal cause on stderr when the parent drains stderr late', async () => {
    // stderr pipes are asynchronous on macOS, so console.error queues while the
    // parent is not reading. Exiting straight after the write used to discard that
    // queue, losing both fatal lines while earlier output survived — the same
    // silence this handler exists to remove.
    session = new Session({ drainStderr: false });
    await session.initialize();

    // Each bad line is chased by a parsed notification so the desync counter
    // resets and the flood reaches the stderr pipe cap instead of the
    // consecutive-error threshold (which would exit long before the pipe fills).
    for (let i = 0; i < STDERR_FLOOD_LINES; i += 1) {
      session.write(`not json ${i}\n`);
      session.send({ jsonrpc: '2.0', method: 'notifications/initialized' });
    }
    session.write(overflowChunk());

    await new Promise((resolve) => setTimeout(resolve, LATE_DRAIN_DELAY_MS));
    session.drainStderr();

    const code = await session.waitForExit();
    expect(session.stderr).toMatch(/transport error: .*ReadBuffer/);
    expect(session.stderr).toContain('transport closed after an error, exiting');
    expect(code).toBe(1);
  }, 30000);

  it('still exits 0 on a clean stdin close', async () => {
    session = new Session();
    await session.initialize();

    session.child.stdin.end();

    const code = await session.waitForExit();
    expect(code).toBe(0);
    expect(session.stderr).not.toContain('transport error');
    expect(session.stderr).not.toContain('exiting');
    expect(session.stdinErrors).toEqual([]);
  }, 20000);
});

describe('frame desync: consecutive parse failures without a parsed message are fatal', () => {
  // Issue #218: with line framing, a healthy peer resyncs at the next newline,
  // so a run of failures with zero successes means the stream itself is broken
  // (foreign output on stdin, pretty-printed JSON, a non-MCP client). Staying
  // alive there is the exact "alive but permanently unanswerable" state PR #214
  // removed for the overflow path.

  it('exits non-zero with the cause after the threshold of consecutive failures', async () => {
    session = new Session();
    await session.initialize();

    for (let i = 0; i < MAX_CONSECUTIVE_TRANSPORT_ERRORS; i += 1) {
      session.write(`still not json ${i}\n`);
    }

    const code = await session.waitForExit();
    // Pin the diagnostics, not just the exit: the count, the "last:" fragment
    // carrying the final underlying error, and the exit marker.
    expect(session.stderr).toContain(
      `${MAX_CONSECUTIVE_TRANSPORT_ERRORS} consecutive transport errors`,
    );
    expect(session.stderr).toMatch(/last: .*not valid JSON/);
    expect(session.stderr).toContain('exiting');
    expect(code).toBe(1);
  }, 20000);

  it('pins the decided threshold value', () => {
    // The behavior tests above import this same constant and would track any
    // value; this pins the issue #218 decision so changing 20 must be deliberate.
    expect(MAX_CONSECUTIVE_TRANSPORT_ERRORS).toBe(20);
  });

  it('resets the counter on a successfully parsed message', async () => {
    session = new Session();
    await session.initialize();

    // Two sub-threshold bursts with one good message between them: combined they
    // exceed the threshold, so surviving both proves the reset actually happens.
    for (let i = 0; i < MAX_CONSECUTIVE_TRANSPORT_ERRORS - 1; i += 1) {
      session.write(`burst one ${i}\n`);
    }
    const first = await session.request(2, 'tools/list');
    expect(first.result.tools.length).toBeGreaterThan(0);

    for (let i = 0; i < MAX_CONSECUTIVE_TRANSPORT_ERRORS - 1; i += 1) {
      session.write(`burst two ${i}\n`);
    }
    const second = await session.request(3, 'tools/list');
    expect(second.result.tools.length).toBeGreaterThan(0);

    expect(session.stderr).not.toContain('exiting');
    expect(session.child.exitCode).toBeNull();
  }, 20000);

  it('reports exactly one fatal cause when the threshold error is also the overflow', async () => {
    session = new Session();
    await session.initialize();

    for (let i = 0; i < MAX_CONSECUTIVE_TRANSPORT_ERRORS - 1; i += 1) {
      session.write(`almost there ${i}\n`);
    }
    session.write(overflowChunk());

    const code = await session.waitForExit();
    // The overflow is the Nth consecutive error, so the threshold path and the
    // close-after-error path fire on the same Error object. First-call-wins must
    // keep that to a single exit message; the losing cause may appear only on a
    // "suppressed" line.
    const fatalLines = session.stderr
      .split('\n')
      .filter((line) => line.includes('exiting') && !line.includes('suppressed'));
    expect(fatalLines).toHaveLength(1);
    expect(fatalLines[0]).toContain('consecutive transport errors');
    // The "last:" fragment must still identify the overflow as the final error.
    expect(fatalLines[0]).toContain('ReadBuffer');
    expect(code).toBe(1);
  }, 20000);

  it('stops serving once the threshold is hit, even while the exit waits on stderr', async () => {
    // With stderr blocked, exitFatal's flush wait keeps the process alive for up
    // to FATAL_FLUSH_TIMEOUT_MS. The transport must already be closed then: a
    // server committed to dying must not answer one more request.
    session = new Session({ drainStderr: false });
    await session.initialize();

    // Fill the stderr pipe first (resets interleaved so the threshold stays
    // untripped), then trip the threshold and ask for one more tool call.
    for (let i = 0; i < STDERR_FLOOD_LINES; i += 1) {
      session.write(`fill ${i}\n`);
      session.send({ jsonrpc: '2.0', method: 'notifications/initialized' });
    }
    for (let i = 0; i < MAX_CONSECUTIVE_TRANSPORT_ERRORS; i += 1) {
      session.write(`tripwire ${i}\n`);
    }
    session.send({ jsonrpc: '2.0', id: 2, method: 'tools/list' });

    await new Promise((resolve) => setTimeout(resolve, LATE_DRAIN_DELAY_MS));
    session.drainStderr();

    const code = await session.waitForExit();
    expect(code).toBe(1);
    expect(session.stderr).toContain('consecutive transport errors');
    expect(session.hasResponse(2)).toBe(false);
  }, 30000);
});

describe('protocol-level failures are reported without ending the process', () => {
  /** A well-formed response envelope for an id the server never requested. */
  const unsolicitedResponse = (id: number, result: unknown = {}) =>
    JSON.stringify({ jsonrpc: '2.0', id, result });

  it('logs a response for an unknown message id and keeps serving', async () => {
    session = new Session();
    await session.initialize();

    session.write(`${unsolicitedResponse(999)}\n`);

    // Regression guard: with Server.onerror unset, this arrived at the SDK's
    // protocol handler and vanished — no log, nothing observable.
    const list = await session.request(2, 'tools/list');
    expect(list.result.tools.length).toBeGreaterThan(0);

    expect(session.stderr).toContain('protocol error:');
    expect(session.stderr).toContain('unknown message ID');
    expect(session.stderr).not.toContain('exiting');
    expect(session.child.exitCode).toBeNull();
  }, 20000);

  it('caps an oversized protocol error message', async () => {
    session = new Session();
    await session.initialize();

    // The SDK embeds the whole offending message in the error text, so a large
    // payload produces an error well past the cap.
    session.write(`${unsolicitedResponse(998, { data: 'x'.repeat(2000) })}\n`);

    await session.request(2, 'tools/list');

    const line = session.stderr.split('\n').find((l) => l.includes('protocol error:'));
    expect(line).toBeDefined();
    expect(line).toContain('chars total');
    // Cap (300) plus prefix and truncation suffix — far below the raw ~2 KB.
    expect(line!.length).toBeLessThan(400);
  }, 20000);

  it('does not double-log transport errors through the protocol handler', async () => {
    session = new Session();
    // The SDK forwards every transport onerror into the protocol handler too;
    // one bad line must produce exactly one stderr line, not two.
    session.write('this is not json\n');

    await session.initialize();

    expect(session.stderr.match(/transport error:/g)).toHaveLength(1);
    expect(session.stderr).not.toContain('protocol error:');
  }, 20000);

  it('reports an envelope that fits no message shape via the transport path', async () => {
    session = new Session();
    await session.initialize();

    // Valid JSON but neither request, notification, nor response. The message
    // schema rejects it at deserialization, so it surfaces as a transport error —
    // the protocol-level "unknown message type" branch is unreachable from the
    // wire. Covered here to pin where the report happens.
    session.write(`${JSON.stringify({ jsonrpc: '2.0', foo: 'bar' })}\n`);

    const list = await session.request(2, 'tools/list');
    expect(list.result.tools.length).toBeGreaterThan(0);

    expect(session.stderr).toContain('transport error:');
    expect(session.stderr).not.toContain('exiting');
    expect(session.child.exitCode).toBeNull();
  }, 20000);
});

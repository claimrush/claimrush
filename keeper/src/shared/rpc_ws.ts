/**
 * JSON-RPC 2.0 over WebSocket — backed by the `ws` library.
 *
 * Targets the Base L2 `eth_subscribe` endpoints (`logs`, `newHeads`) with
 * auto-reconnect, ping/pong liveness, bounded payload/message size, and
 * disabled per-message deflate (to avoid compression bombs) and redirects.
 *
 * `serializeError` is imported from `@claimrush/node-utils/logger`. The raw
 * RPC types (`RpcLog`, `RpcBlockHeader`, `WsPendingRequest`) are defined
 * inline: the keeper uses a narrower surface than a general-purpose subscriber.
 */

import WebSocket from 'ws';
import { serializeError } from '@claimrush/node-utils/logger';

const WS_HANDSHAKE_TIMEOUT_MS = 10_000;
const WS_MAX_PAYLOAD_BYTES = 8 * 1024 * 1024;
export const WS_MAX_MESSAGE_JSON_CHARS = 1_000_000;
const WS_PING_INTERVAL_MS = 25_000;
const WS_PONG_TIMEOUT_MS = 60_000;

export interface RpcLog {
  address: string;
  topics: string[];
  data: string;
  blockNumber: string;
  blockHash: string;
  transactionHash: string;
  logIndex: string;
  removed?: boolean;
}

export interface RpcBlockHeader {
  number: string;
  hash: string;
  timestamp: string;
  [key: string]: unknown;
}

export interface WsPendingRequest {
  resolve: (value: unknown) => void;
  reject: (reason?: unknown) => void;
  timeoutId: ReturnType<typeof setTimeout>;
}

function stringifyError(err: unknown): string {
  const e = serializeError(err);
  if (e.stack) return e.stack;
  if (e.name) return `${e.name}: ${e.message}`;
  return e.message;
}

function rawDataToString(data: WebSocket.RawData): string {
  if (typeof data === 'string') return data;
  if (Buffer.isBuffer(data)) return data.toString('utf8');
  if (Array.isArray(data)) return Buffer.concat(data).toString('utf8');
  return Buffer.from(data).toString('utf8');
}

function parseRpcResponseId(value: unknown): number | null {
  if (typeof value === 'number') {
    return Number.isSafeInteger(value) && value >= 0 ? value : null;
  }
  if (typeof value !== 'string') return null;
  const raw = value.trim();
  if (!/^(?:0|[1-9]\d*)$/.test(raw)) return null;
  const parsed = Number(raw);
  return Number.isSafeInteger(parsed) ? parsed : null;
}

export function parseRpcWsMessage(data: WebSocket.RawData): Record<string, unknown> | null {
  const text = rawDataToString(data);
  if (!text || text.length > WS_MAX_MESSAGE_JSON_CHARS) return null;

  const parsed = JSON.parse(text) as unknown;
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
  return parsed as Record<string, unknown>;
}

function isValidRpcLog(obj: unknown): boolean {
  if (!obj || typeof obj !== 'object') return false;
  const o = obj as Record<string, unknown>;
  return (
    typeof o.blockNumber === 'string' &&
    typeof o.logIndex === 'string' &&
    typeof o.transactionHash === 'string' &&
    typeof o.blockHash === 'string' &&
    Array.isArray(o.topics) &&
    typeof o.data === 'string' &&
    typeof o.address === 'string'
  );
}

function isValidBlockHeader(obj: unknown): boolean {
  if (!obj || typeof obj !== 'object') return false;
  const o = obj as Record<string, unknown>;
  return typeof o.number === 'string' && typeof o.timestamp === 'string';
}

export class RpcWs {
  url: string;
  requestTimeoutMs: number;
  onLog: ((msg: string) => void) | null;
  ws: WebSocket | null;
  pingInterval: ReturnType<typeof setInterval> | null;
  lastPongAtMs: number;
  nextId: number;
  /** id -> pending request metadata. */
  pending: Map<number, WsPendingRequest>;
  /** subId -> callback */
  subCallbacks: Map<string, (result: unknown) => void>;
  onClose: (() => void) | null;

  constructor(
    url: string,
    {
      requestTimeoutMs = 20_000,
      onLog = null,
    }: { requestTimeoutMs?: number; onLog?: ((msg: string) => void) | null } = {},
  ) {
    this.url = url;
    this.requestTimeoutMs = requestTimeoutMs;
    this.onLog = onLog;

    this.ws = null;
    this.pingInterval = null;
    this.lastPongAtMs = 0;
    // nextId resets on each connect(); see connect().
    this.nextId = 1;
    this.pending = new Map();
    this.subCallbacks = new Map();

    this.onClose = null;
  }

  async connect(): Promise<void> {
    if (
      this.ws &&
      (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING)
    ) {
      return;
    }

    const ws = new WebSocket(this.url, {
      handshakeTimeout: WS_HANDSHAKE_TIMEOUT_MS,
      maxPayload: WS_MAX_PAYLOAD_BYTES,
      perMessageDeflate: false,
      followRedirects: false,
    });
    this.ws = ws;
    this.nextId = 1;
    this.pending.clear();
    this.subCallbacks.clear();

    ws.on('message', (data: WebSocket.RawData) => {
      try {
        const msg = parseRpcWsMessage(data);
        if (!msg) {
          this.#log('[rpc_ws] Dropping invalid or oversized JSON message');
          return;
        }
        this.#handleMessage(msg);
      } catch (e) {
        this.#log(`[rpc_ws] Bad JSON message: ${stringifyError(e)}`);
      }
    });

    ws.on('pong', () => {
      this.lastPongAtMs = Date.now();
    });

    ws.on('close', () => {
      if (this.pingInterval) {
        clearInterval(this.pingInterval);
        this.pingInterval = null;
      }
      this.ws = null;
      for (const [, p] of this.pending) {
        clearTimeout(p.timeoutId);
        p.reject(new Error('WebSocket closed'));
      }
      this.pending.clear();
      // Subscriptions are invalidated by a connection drop.
      this.subCallbacks.clear();

      if (typeof this.onClose === 'function') {
        try {
          this.onClose();
        } catch {
          // ignore
        }
      }
    });

    ws.on('error', (err: Error) => {
      this.#log(`[rpc_ws] WebSocket error: ${stringifyError(err)}`);
    });

    await new Promise<void>((resolve, reject) => {
      const onOpen = (): void => {
        this.lastPongAtMs = Date.now();
        if (this.pingInterval) {
          clearInterval(this.pingInterval);
          this.pingInterval = null;
        }
        this.pingInterval = setInterval(() => {
          const sock = this.ws;
          if (!sock || sock.readyState !== WebSocket.OPEN) return;
          const now = Date.now();
          if (this.pending.size > 100) {
            for (const [id, p] of this.pending) {
              if (this.pending.size <= 100) break;
              clearTimeout(p.timeoutId);
              this.pending.delete(id);
              p.reject(new Error('RPC request stale (sweep)'));
            }
          }
          if (this.lastPongAtMs && now - this.lastPongAtMs > WS_PONG_TIMEOUT_MS) {
            this.#log('[rpc_ws] Pong timeout — terminating socket');
            try {
              sock.terminate();
            } catch {
              try {
                sock.close();
              } catch {
                // ignore
              }
            }
            return;
          }
          try {
            sock.ping();
          } catch {
            // ignore
          }
        }, WS_PING_INTERVAL_MS);
        // Never keep the Node process alive solely for the ping interval.
        (this.pingInterval as { unref?: () => void } | null)?.unref?.();

        cleanup();
        resolve();
      };
      const onError = (err: Error): void => {
        cleanup();
        reject(err);
      };
      const onClose = (): void => {
        cleanup();
        reject(new Error('WebSocket closed before open'));
      };
      const cleanup = (): void => {
        ws.off('open', onOpen);
        ws.off('error', onError);
        ws.off('close', onClose);
      };
      ws.on('open', onOpen);
      ws.on('error', onError);
      ws.on('close', onClose);
    });
  }

  close(): void {
    const ws = this.ws;
    this.ws = null;

    if (this.pingInterval) {
      clearInterval(this.pingInterval);
      this.pingInterval = null;
    }
    this.lastPongAtMs = 0;
    for (const [, p] of this.pending) {
      clearTimeout(p.timeoutId);
      p.reject(new Error('WebSocket closed'));
    }
    this.pending.clear();
    this.subCallbacks.clear();

    if (!ws) return;
    try {
      ws.close();
    } catch {
      // ignore
    }
  }

  isOpen(): boolean {
    return this.ws?.readyState === WebSocket.OPEN;
  }

  async request(method: string, params: unknown[] = []): Promise<unknown> {
    if (!this.ws) throw new Error('WebSocket not connected');
    if (this.ws.readyState !== WebSocket.OPEN) throw new Error('WebSocket not open');

    if (this.pending.size > 150) {
      throw new Error(
        `RPC request backlog exceeded (${this.pending.size} pending). Connection likely dead.`,
      );
    }

    const id = this.nextId++;
    const payload = { jsonrpc: '2.0', id, method, params };

    const p: Promise<unknown> = new Promise((resolve, reject) => {
      const timeoutId = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`RPC timeout: ${method}`));
      }, this.requestTimeoutMs);

      this.pending.set(id, { resolve, reject, timeoutId });
    });

    try {
      this.ws.send(JSON.stringify(payload));
    } catch (e) {
      const pending = this.pending.get(id);
      if (pending) {
        clearTimeout(pending.timeoutId);
        this.pending.delete(id);
      }
      throw e;
    }

    return p;
  }

  async subscribeLogs(
    filter: { address: string[]; topics: Array<string | string[] | null> },
    onLog: (log: RpcLog) => void,
  ): Promise<string> {
    const subIdRaw = await this.request('eth_subscribe', ['logs', filter]);
    if (typeof subIdRaw !== 'string' || !subIdRaw) {
      throw new Error(`eth_subscribe('logs') returned invalid subscription ID: ${typeof subIdRaw}`);
    }
    const subId = subIdRaw;
    this.subCallbacks.set(subId, (result: unknown) => {
      if (!isValidRpcLog(result)) {
        this.#log('[rpc_ws] Dropping invalid log subscription result');
        return;
      }
      onLog(result as RpcLog);
    });
    return subId;
  }

  async subscribeNewHeads(onHead: (header: RpcBlockHeader) => void): Promise<string> {
    const subIdRaw = await this.request('eth_subscribe', ['newHeads']);
    if (typeof subIdRaw !== 'string' || !subIdRaw) {
      throw new Error(
        `eth_subscribe('newHeads') returned invalid subscription ID: ${typeof subIdRaw}`,
      );
    }
    const subId = subIdRaw;
    this.subCallbacks.set(subId, (result: unknown) => {
      if (!isValidBlockHeader(result)) {
        this.#log('[rpc_ws] Dropping invalid newHeads subscription result');
        return;
      }
      onHead(result as RpcBlockHeader);
    });
    return subId;
  }

  async unsubscribe(subId: string): Promise<void> {
    try {
      await this.request('eth_unsubscribe', [subId]);
    } finally {
      this.subCallbacks.delete(subId);
    }
  }

  #handleMessage(msg: unknown): void {
    if (msg == null || typeof msg !== 'object') return;
    const m = msg as Record<string, unknown>;

    if (m.id != null) {
      const numericId = parseRpcResponseId(m.id);
      if (numericId == null) return;

      const pending = this.pending.get(numericId);
      if (!pending) return;

      clearTimeout(pending.timeoutId);
      this.pending.delete(numericId);

      if (m.error) {
        const errObj = m.error as { message?: string };
        pending.reject(new Error(errObj?.message || 'RPC error'));
      } else {
        pending.resolve(m.result);
      }
      return;
    }

    if (m.method === 'eth_subscription' && m.params) {
      const params = m.params as { subscription: string; result: unknown };
      const subId = params.subscription;
      if (typeof subId !== 'string' || !subId) return;

      if (params.result === null || params.result === undefined) {
        this.#log(`[rpc_ws] Dropping null/undefined subscription result for sub=${subId}`);
        return;
      }

      const cb = this.subCallbacks.get(subId);
      if (typeof cb === 'function') {
        try {
          cb(params.result);
        } catch (e) {
          this.#log(`[rpc_ws] Subscription handler error: ${stringifyError(e)}`);
        }
      }
    }
  }

  #log(line: string): void {
    if (typeof this.onLog === 'function') this.onLog(line);
    else console.log(line);
  }
}

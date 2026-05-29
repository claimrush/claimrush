export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

export type LogFields = Record<string, unknown>;

export type NodeLogger = ((message: string, fields?: LogFields) => void) & {
  debug: (message: string, fields?: LogFields) => void;
  info: (message: string, fields?: LogFields) => void;
  warn: (message: string, fields?: LogFields) => void;
  error: (message: string, fields?: LogFields) => void;
  child: (extra: LogFields) => NodeLogger;
};

/**
 * Create a structured JSON logger for Node.js services.
 *
 * Standard fields for observability consistency:
 *   - `component`  — service name (e.g. "event-watcher", "keeper")
 *   - `nodeId`     — instance / deployment identifier
 *   - `chainId`    — EVM chain ID
 *   - `requestId`  — correlation ID propagated across services
 */
export function makeNodeLogger(baseFields?: LogFields): NodeLogger;

/**
 * Emit a single metric data point as a structured JSON log line.
 */
export function emitMetric(
  name: string,
  value: number,
  kind?: 'counter' | 'gauge' | 'timing',
  labels?: LogFields,
): void;

/**
 * Emit a timing metric (convenience wrapper).
 */
export function emitTiming(name: string, durationMs: number, labels?: LogFields): void;

/**
 * Serialize an unknown error into safe, redacted, bounded fields.
 *
 * Intended usage:
 *   log.error('something_failed', { error: serializeError(err) })
 */
export function serializeError(err: unknown): {
  name?: string;
  message: string;
  stack?: string;
};

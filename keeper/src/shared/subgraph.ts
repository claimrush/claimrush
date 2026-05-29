/**
 * Minimal subgraph GraphQL client for the keeper.
 * No external dependencies — uses native fetch.
 */

export interface SubgraphResponse<T = unknown> {
  data?: T;
  errors?: Array<{ message: string }>;
}

const SUBGRAPH_MAX_RESPONSE_BYTES = 2_000_000;
const SUBGRAPH_ERROR_SNIPPET_BYTES = 64_000;

async function readResponseTextUpTo(
  res: Response,
  maxBytes: number,
): Promise<{ text: string; exceeded: boolean }> {
  const body = res.body;
  if (!body) return { text: '', exceeded: false };

  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  let exceeded = false;

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value || value.byteLength === 0) continue;

      const remaining = maxBytes - total;
      if (remaining <= 0) {
        exceeded = true;
        try {
          await reader.cancel();
        } catch {
          // ignore
        }
        break;
      }

      if (value.byteLength > remaining) {
        chunks.push(value.slice(0, remaining));
        total += remaining;
        exceeded = true;
        try {
          await reader.cancel();
        } catch {
          // ignore
        }
        break;
      }

      chunks.push(value);
      total += value.byteLength;
    }
  } finally {
    try {
      reader.releaseLock();
    } catch {
      // ignore
    }
  }

  const buf = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    buf.set(chunk, offset);
    offset += chunk.byteLength;
  }

  return { text: new TextDecoder().decode(buf), exceeded };
}

export async function querySubgraph<T = unknown>(
  url: string,
  query: string,
  variables?: Record<string, unknown>,
  timeoutMs = 15_000,
): Promise<T> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const res = await fetch(url, {
      method: 'POST',
      redirect: 'manual',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ query, variables }),
      signal: controller.signal,
    });

    const limit = res.ok ? SUBGRAPH_MAX_RESPONSE_BYTES : SUBGRAPH_ERROR_SNIPPET_BYTES;
    const { text, exceeded } = await readResponseTextUpTo(res, limit);

    if (!res.ok) {
      const suffix = exceeded ? '...[truncated]' : '';
      throw new Error(`subgraph HTTP ${res.status}: ${text}${suffix}`);
    }

    if (exceeded) {
      throw new Error(`subgraph response exceeded max size (${SUBGRAPH_MAX_RESPONSE_BYTES} bytes)`);
    }

    const contentType = (res.headers.get('content-type') ?? '').toLowerCase();
    if (contentType && !contentType.includes('application/json')) {
      throw new Error(`subgraph unexpected content-type: ${contentType}`);
    }

    let json: SubgraphResponse<T>;
    try {
      json = JSON.parse(text) as SubgraphResponse<T>;
    } catch {
      throw new Error('subgraph returned invalid JSON');
    }

    if (json.errors?.length) {
      throw new Error(`subgraph query error: ${json.errors[0].message}`);
    }

    if (!json.data) {
      throw new Error('subgraph returned no data');
    }

    return json.data;
  } finally {
    clearTimeout(timer);
  }
}

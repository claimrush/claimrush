/**
 * Small helpers for safely reading fetch() responses.
 *
 * Goals:
 * - prevent unbounded memory growth when parsing JSON from remote endpoints
 * - allow callers to enforce response size limits
 * - surface read-path errors distinctly from "legitimately empty body" so
 *   callers can tell the difference between "server returned 204" and
 *   "stream aborted mid-response"
 *
 * Return shape:
 *   { text, truncated, readError? }
 *
 * `readError` is set to a short human-readable string ONLY when a read-path
 * exception was swallowed (network reset mid-read, decode failure, etc.);
 * otherwise it is omitted. Callers that want to distinguish "empty body"
 * from "read failed" can branch on `readError`.
 */
export async function readResponseTextLimited(
  res: Response,
  maxBytes: number,
): Promise<{ text: string; truncated: boolean; readError?: string }> {
  const limit = Math.max(1, Math.floor(maxBytes));

  try {
    const body = res.body;
    if (!body) return { text: '', truncated: false };

    const reader = body.getReader();
    const decoder = new TextDecoder();

    let out = '';
    let total = 0;
    let truncated = false;

    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      if (!value || value.byteLength === 0) continue;

      const remaining = limit - total;
      if (remaining <= 0) {
        truncated = true;
        try {
          await reader.cancel();
        } catch {
          // ignore
        }
        break;
      }

      let chunk = value;
      if (value.byteLength > remaining) {
        chunk = value.slice(0, remaining);
        truncated = true;
      }

      total += chunk.byteLength;
      out += decoder.decode(chunk, { stream: true });

      if (truncated) {
        try {
          await reader.cancel();
        } catch {
          // ignore
        }
        break;
      }
    }

    out += decoder.decode();
    return { text: out, truncated };
  } catch (err) {
    const msg = String((err as Error)?.message ?? err).slice(0, 256);
    return { text: '', truncated: false, readError: msg };
  }
}

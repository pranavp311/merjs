export async function runBounded(items, concurrency, worker, onError) {
  let next = 0;
  let firstError;
  const runners = Array.from(
    { length: Math.min(concurrency, items.length) },
    async () => {
      while (next < items.length && firstError === undefined) {
        try {
          await worker(items[next++]);
        } catch (error) {
          firstError ??= error;
          onError(error);
        }
      }
    },
  );
  await Promise.all(runners);
  if (firstError !== undefined) throw firstError;
}

export async function readBoundedBody(response, limit, signal) {
  const contentLength = response.headers.get("content-length");
  if (contentLength !== null && Number(contentLength) > limit) {
    await response.body?.cancel("fetch response too large").catch(() => {});
    throw new Error("fetch response too large");
  }
  if (!response.body) return new Uint8Array();

  const reader = response.body.getReader();
  const chunks = [];
  let length = 0;
  let complete = false;
  const cancel = () => { void reader.cancel(signal?.reason).catch(() => {}); };
  signal?.addEventListener("abort", cancel, { once: true });
  try {
    while (true) {
      if (signal?.aborted) throw signal.reason;
      const { done, value } = await reader.read();
      if (signal?.aborted) throw signal.reason;
      if (done) { complete = true; break; }
      if (value.byteLength > limit - length)
        throw new Error("fetch response too large");
      chunks.push(value);
      length += value.byteLength;
    }
  } finally {
    signal?.removeEventListener("abort", cancel);
    if (!complete) await reader.cancel(signal?.reason || "fetch body read failed").catch(() => {});
    reader.releaseLock();
  }
  const body = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

export async function collectFetchRounds(options) {
  const {
    maxRounds,
    maxRequests,
    maxRequestBytes,
    maxDurationMs = 30000,
    restore,
    collect,
    fetchRound,
  } = options;
  const controller = new AbortController();
  const timeout = setTimeout(
    () => controller.abort(new Error("fetch protocol deadline exceeded")),
    maxDurationMs,
  );
  let expectedState = new Uint8Array();
  const results = [];
  let requestBytes = 0;

  try {
    for (let round = 0; round < maxRounds; round++) {
      // Round zero starts from the application snapshot and has no protocol
      // state yet. Later rounds restore only validated, versioned state.
      if (expectedState.byteLength !== 0 || results.length !== 0)
        restore(expectedState, results);
      const collected = collect(results.length);
      if (!collected || !Number.isInteger(collected.errorCode) ||
          !Number.isInteger(collected.requestBytes) || collected.requestBytes < 0 ||
          !(collected.expectedState instanceof Uint8Array) || !Array.isArray(collected.requests))
        throw new Error("invalid WASM fetch collection");
      if (collected.errorCode !== 0)
        throw new Error(`WASM fetch collection error ${collected.errorCode}`);
      if (collected.requestBytes > maxRequestBytes - requestBytes)
        throw new Error("total fetch request bytes exceeded");
      requestBytes += collected.requestBytes;
      expectedState = collected.expectedState;
      if (collected.requests.length === 0) {
        restore(expectedState, results);
        return { requestBytes, responseCount: results.length };
      }
      if (results.length + collected.requests.length > maxRequests)
        throw new Error("too many fetch requests");
      const expectedResults = results.length + collected.requests.length;
      await fetchRound(collected.requests, results, controller.signal);
      if (results.length !== expectedResults || results.includes(undefined) || results.includes(null))
        throw new Error("incomplete fetch round");
    }
    throw new Error("fetch round limit exceeded");
  } catch (error) {
    controller.abort(error);
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

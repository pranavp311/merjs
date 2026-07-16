// worker.js — Cloudflare Workers fetch handler for merjs (merlionjs.com).

import merWasm from "./merjs.wasm";
import grepWasm from "./grep.wasm";
import { AiAdmissionError, authorizePaidOperation, createAiAdmission } from "./ai-budget.js";

const merModule = Promise.resolve(merWasm).then(source =>
  source instanceof WebAssembly.Module ? source : WebAssembly.compile(source));
const grepModule = Promise.resolve(grepWasm).then(source =>
  source instanceof WebAssembly.Module ? source : WebAssembly.compile(source));

async function createInstance(module) {
  const instantiated = await WebAssembly.instantiate(await module, {});
  return instantiated.exports || instantiated;
}

async function createMerInstance() {
  const wasm = await createInstance(merModule);
  wasm.init();
  return wasm;
}

async function createGrepInstance() {
  return createInstance(grepModule);
}

// Explicit demo policy: the site uses inline examples, browser WASM, CDNs, and APIs.
const securityHeaders = {
  "strict-transport-security": "max-age=63072000; includeSubDomains; preload",
  "content-security-policy": "default-src 'self'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval' blob: https://cdn.jsdelivr.net https://unpkg.com https://static.cloudflareinsights.com https://fonts.googleapis.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://unpkg.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self' https://api.open-meteo.com https://cloudflareinsights.com; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
  "x-frame-options": "DENY",
  "x-content-type-options": "nosniff",
  "referrer-policy": "strict-origin-when-cross-origin",
  "cross-origin-opener-policy": "same-origin",
  "permissions-policy": "camera=(), microphone=(), geolocation=()",
};

function workerResponse(body, init = {}) {
  const headers = new Headers(securityHeaders);
  if (Array.isArray(init.headers)) {
    for (const [name, value] of init.headers) headers.append(name, value);
  } else {
    new Headers(init.headers || {}).forEach((value, name) => headers.append(name, value));
  }
  return new Response(body, { ...init, headers });
}

const RESPONSE_MAGIC = 0x3152454d;
const RESPONSE_VERSION = 1;
const MAX_RESPONSE_HEADERS = 10;
const MAX_RESPONSE_HEADER_NAME_BYTES = 64;
const MAX_RESPONSE_HEADER_VALUE_BYTES = 4096;
const MAX_RESPONSE_HEADER_BYTES = 32 * 1024;
const headerNamePattern = /^[!#$%&'*+.^_`|~0-9a-z-]+$/;

function decodeWorkerResponse(bytes, decoder) {
  if (bytes.byteLength < 16 || bytes.byteLength > 32 * 1024 * 1024) throw new Error("invalid WASM response size");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (view.getUint32(0, true) !== RESPONSE_MAGIC || view.getUint16(4, true) !== RESPONSE_VERSION || view.getUint16(10, true) !== 0)
    throw new Error("unsupported WASM response protocol");
  const status = view.getUint16(6, true);
  const count = view.getUint16(8, true);
  const bodyLength = view.getUint32(12, true);
  if (status < 100 || status > 599 || count === 0 || count > MAX_RESPONSE_HEADERS) throw new Error("invalid WASM response metadata");
  const headers = [];  let offset = 16;
  let contentTypes = 0;
  let locations = 0;
  for (let i = 0; i < count; i++) {
    if (offset + 6 > bytes.byteLength) throw new Error("truncated WASM response header");
    const nameLength = view.getUint16(offset, true);
    const valueLength = view.getUint32(offset + 2, true);
    offset += 6;
    if (!nameLength || nameLength > MAX_RESPONSE_HEADER_NAME_BYTES || valueLength > MAX_RESPONSE_HEADER_VALUE_BYTES ||
        offset + nameLength + valueLength > bytes.byteLength || offset + nameLength + valueLength - 16 > MAX_RESPONSE_HEADER_BYTES)
      throw new Error("invalid WASM response header length");
    const name = decoder.decode(bytes.subarray(offset, offset + nameLength));
    offset += nameLength;
    const value = decoder.decode(bytes.subarray(offset, offset + valueLength));
    offset += valueLength;
    if (!headerNamePattern.test(name) || /[\0\r\n\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(value) ||
        (name !== "content-type" && name !== "location" && name !== "set-cookie")) throw new Error("invalid WASM response header");
    if (name === "content-type") contentTypes++;
    if (name === "location") locations++;
    headers.push([name, value]);  }
  if (contentTypes !== 1 || locations > 1 || offset + bodyLength !== bytes.byteLength ||
      (locations === 1) !== (status >= 300 && status < 400)) throw new Error("inconsistent WASM response metadata");
  return { status, headers, body: bytes.slice(offset) };
}

const resolverScript = "(()=>{for(const s of document.querySelectorAll('template[data-mer-resolve]')){for(const p of document.querySelectorAll('[data-mer-placeholder]')){if(p.getAttribute('data-mer-placeholder')===s.getAttribute('data-mer-resolve')){p.replaceWith(s.content);s.remove();break}}}})();";

function resolverResponse(request) {
  return workerResponse(request.method === "HEAD" ? null : resolverScript, {
    status: 200,
    headers: {
      "content-type": "application/javascript; charset=utf-8",
      "cache-control": "public, max-age=3600",
      "x-content-type-options": "nosniff",
    },
  });
}

function injectEnv(wasm, env) {
  if (!wasm.__mer_set_env_status)
    throw new Error("WASM module does not expose observable environment injection");
  const encoder = new TextEncoder();
  for (const [key, value] of Object.entries(env)) {
    if (typeof value !== "string") continue;
    const keyBytes = encoder.encode(key);
    const valueBytes = encoder.encode(value);
    const keyPtr = keyBytes.length === 0 ? 0 : wasm.alloc(keyBytes.length);
    const valuePtr = valueBytes.length === 0 ? 0 : wasm.alloc(valueBytes.length);
    try {
      if ((keyBytes.length !== 0 && !keyPtr) || (valueBytes.length !== 0 && !valuePtr))
        throw new Error(`WASM env allocation failed for ${key}`);
      const memory = new Uint8Array(wasm.memory.buffer);
      memory.set(keyBytes, keyPtr);
      memory.set(valueBytes, valuePtr);
      const status = wasm.__mer_set_env_status(keyPtr, keyBytes.length, valuePtr, valueBytes.length);
      if (status !== 0) throw new Error(`WASM env injection failed for ${key}: ${status}`);
    } finally {
      if (keyBytes.length !== 0 && keyPtr) wasm.dealloc(keyPtr, keyBytes.length);
      if (valueBytes.length !== 0 && valuePtr) wasm.dealloc(valuePtr, valueBytes.length);
    }
  }
}

function jsonResp(data, status = 200) {
  return workerResponse(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// ── R2 grep search (WASM-powered, no embeddings) ──────────────────────────────

let cachedChunks = null;

async function getChunks(env) {
  if (cachedChunks) return cachedChunks;
  const obj = await env.BUCKET.get("budget2026/all_chunks.json");
  if (!obj) return [];
  cachedChunks = JSON.parse(await obj.text());
  return cachedChunks;
}

// Pack chunk texts into length-prefixed binary for WASM: [u32-LE len][text]...
function packChunks(chunks) {
  const encoder = new TextEncoder();
  const encoded = chunks.map(c => encoder.encode(c.text));
  const totalLen = encoded.reduce((sum, e) => sum + 4 + e.length, 0);
  const buf = new Uint8Array(totalLen);
  let off = 0;
  for (const e of encoded) {
    buf[off] = e.length & 0xff;
    buf[off + 1] = (e.length >> 8) & 0xff;
    buf[off + 2] = (e.length >> 16) & 0xff;
    buf[off + 3] = (e.length >> 24) & 0xff;
    off += 4;
    buf.set(e, off);
    off += e.length;
  }
  return buf;
}

async function grepChunks(chunks, query) {
  const grep = await createGrepInstance();
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  // Write query into WASM memory
  const qBytes = encoder.encode(query);
  const qPtr = grep.get_query_ptr();
  const mem = new Uint8Array(grep.memory.buffer);
  mem.set(qBytes, qPtr);

  // Pack and write chunks into WASM memory
  const packed = packChunks(chunks);
  const cPtr = grep.get_chunks_ptr();
  mem.set(packed, cPtr);

  // Run grep in WASM
  grep.grep(qBytes.length, packed.length);

  // Read results
  const rPtr = grep.get_result_ptr();
  const rLen = grep.get_result_len();
  const resultBytes = new Uint8Array(grep.memory.buffer, rPtr, rLen);
  const results = JSON.parse(decoder.decode(resultBytes));

  // Map back: [[index, score], ...] → chunk objects with score
  return results.map(([idx, score]) => ({ ...chunks[idx], score }));
}

const AI_MAX_CONCURRENCY = 2;
const AI_MAX_PER_MINUTE = 10;
let aiActive = 0;
let aiMinute = 0;
let aiMinuteCount = 0;

async function admitAi(request, env, work) {
  if (!env.AI_BEARER_TOKEN)
    return jsonResp({ error: "AI controls are not configured" }, 503);
  if (request.headers.get("authorization") !== `Bearer ${env.AI_BEARER_TOKEN}`)
    return jsonResp({ error: "Unauthorized" }, 401);
  const contentLength = Number(request.headers.get("content-length") || 0);
  if (!Number.isFinite(contentLength) || contentLength > 8192)
    return jsonResp({ error: "AI request too large" }, 413);
  let admission;
  try { admission = createAiAdmission(request, env); }
  catch (error) {
    return jsonResp({ error: error.message }, error instanceof AiAdmissionError ? error.status : 503);
  }
  const minute = Math.floor(Date.now() / 60000);
  if (minute !== aiMinute) { aiMinute = minute; aiMinuteCount = 0; }
  // These isolate-local limits are defense-in-depth only; the shared gate is authoritative.
  if (aiActive >= AI_MAX_CONCURRENCY || aiMinuteCount >= AI_MAX_PER_MINUTE)
    return jsonResp({ error: "AI capacity exceeded" }, 429);
  aiActive++;
  aiMinuteCount++;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15000);
  try { return await work(controller.signal, admission); }
  catch (error) {
    if (error instanceof AiAdmissionError) return jsonResp({ error: error.message }, error.status);
    return jsonResp({ error: "AI upstream unavailable" }, 502);
  } finally { clearTimeout(timeout); aiActive--; }
}

async function readAiJson(request) {
  if (!request.body) throw new Error("missing body");
  const reader = request.body.getReader();
  const chunks = [];
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value.byteLength > 8192 - length) {
        await reader.cancel("body too large");
        throw new Error("body too large");
      }
      chunks.push(value);
      length += value.byteLength;
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
}

async function handleBudgetAi(request, env, signal, admission) {
  let body;
  try { body = await readAiJson(request); } catch { return jsonResp({ error: "Invalid or oversized JSON" }, 400); }
  const question = body?.question;
  if (typeof question !== "string" || !question.trim() || question.length > 512)
    return jsonResp({ error: "question must be 1-512 characters" }, 400);

  const openaiKey = env.OPENAI_API_KEY;
  if (!openaiKey || !env.BUCKET) return jsonResp({ error: "AI upstream is not configured" }, 503);

  // Step 1: Extract search keywords via LLM
  let searchQuery = question;
  await authorizePaidOperation(env, admission, "openai.reform", 0.001, signal);
  try {
    const reformRes = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": `Bearer ${openaiKey}` },
      body: JSON.stringify({
        model: "gpt-4o-mini",
        instructions: "Convert the user's question into a short keyword-focused search query (3-7 words, no question words like 'what/how/when'). Include synonyms for budget terms (e.g. spending=expenditure, money=allocation). Return only the keywords, nothing else.",
        input: question,
        max_output_tokens: 30,
      }),
      signal,
    });
    const reformData = await reformRes.json();
    for (const out of reformData?.output ?? []) {
      if (out.type !== "message") continue;
      for (const c of out.content ?? []) { if (c.text) { searchQuery = c.text.trim(); break; } }
      if (searchQuery !== question) break;
    }
  } catch { /* fall back to raw question */ }

  // Step 2: Grep R2 chunks
  const chunks = await getChunks(env);
  const matched = await grepChunks(chunks, searchQuery);

  let context = "";
  for (const m of matched.slice(0, 8)) {
    const separator = context ? "\n\n---\n\n" : "";
    const chunk = `[Page ${m.page}, score ${m.score}] ${String(m.text || "")}`;
    context += separator + chunk.slice(0, Math.max(0, 12000 - context.length - separator.length));
    if (context.length >= 12000) break;
  }

  // Step 3: Answer with LLM
  const systemPrompt =
    "You are a helpful assistant that answers questions about Singapore's FY2026 Budget Statement. " +
    "Use the provided document context to give accurate, concise answers. " +
    "Cite page numbers when possible. " +
    "If the context doesn't contain relevant information, say so clearly.";

  const userMsg = context
    ? `Context from FY2026 Budget (matched by keyword search):\n${context}\n\nQuestion: ${question}`
    : `No relevant sections were found for this question.\n\nQuestion: ${question}`;

  await authorizePaidOperation(env, admission, "openai.answer", 0.019, signal);
  const chatRes = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${openaiKey}` },
    body: JSON.stringify({
      model: "gpt-4o-mini",
      instructions: systemPrompt,
      input: userMsg.slice(0, 13000),
      max_output_tokens: 1024,
    }),
    signal,
  });
  const chatData = await chatRes.json();

  let answer = "";
  for (const out of chatData?.output ?? []) {
    if (out.type !== "message") continue;
    for (const c of out.content ?? []) { if (c.text) { answer = c.text; break; } }
    if (answer) break;
  }

  if (!answer) return jsonResp({ error: "No answer from AI" }, 502);
  return jsonResp({
    answer: answer.slice(0, 8000),
    method: "r2-grep",
    chunks_searched: chunks.length,
    chunks_matched: matched.length,
    keywords: searchQuery,
  });
}

async function handleBudgetSuggestions(request, env, signal, admission) {
  let body;
  try { body = await readAiJson(request); } catch { return jsonResp({ error: "Invalid or oversized JSON" }, 400); }
  const { question, answer = "" } = body ?? {};
  if (typeof question !== "string" || !question.trim() || question.length > 512 || typeof answer !== "string" || answer.length > 2000)
    return jsonResp({ error: "invalid suggestion input" }, 400);

  const openaiKey = env.OPENAI_API_KEY;
  if (!openaiKey) return jsonResp({ error: "AI upstream is not configured" }, 503);

  const prompt = answer
    ? `User asked about Singapore FY2026 Budget: "${question}"\nAnswer: "${answer.slice(0, 400)}"\n\nGenerate exactly 3 short follow-up questions (under 12 words each). Return ONLY a JSON array of 3 strings.`
    : `User is asking about Singapore FY2026 Budget: "${question}"\n\nGenerate exactly 3 related questions. Return ONLY a JSON array of 3 strings.`;

  await authorizePaidOperation(env, admission, "openai.suggestions", 0.002, signal);
  const res = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${openaiKey}` },
    body: JSON.stringify({
      model: "gpt-4o-mini",
      instructions: "You generate follow-up questions. Return only a JSON array of strings.",
      input: prompt,
      max_output_tokens: 256,
    }),
    signal,
  });
  const data = await res.json();

  let text = "";
  for (const out of data?.output ?? []) {
    if (out.type !== "message") continue;
    for (const c of out.content ?? []) { if (c.text) { text = c.text; break; } }
    if (text) break;
  }

  if (!text) return jsonResp({ suggestions: [] });
  const start = text.indexOf("[");
  const end = text.lastIndexOf("]");
  if (start === -1 || end <= start) return jsonResp({ suggestions: [] });
  try {
    const suggestions = JSON.parse(text.slice(start, end + 1));
    if (!Array.isArray(suggestions)) throw new Error("invalid suggestions");
    return jsonResp({ suggestions: suggestions.slice(0, 3).filter(value => typeof value === "string").map(value => value.slice(0, 100)) });
  } catch {
    return jsonResp({ suggestions: [] });
  }
}

// ── Bounded WASM request and fetch bridge ─────────────────────────────────────

const MAX_INCOMING_REQUEST_BYTES = 2 * 1024 * 1024;
const MAX_INCOMING_TARGET_BYTES = 16 * 1024;
const MAX_INCOMING_BODY_BYTES = 1024 * 1024;
const MAX_INCOMING_COOKIE_BYTES = 16 * 1024;
const MAX_INCOMING_HEADER_BYTES = 64 * 1024;
const FORWARDED_HEADERS = [
  "accept", "authorization", "content-type", "origin", "referer", "user-agent",
];

async function encodeIncomingRequest(request, url, encoder) {
  const method = encoder.encode(request.method);
  const target = encoder.encode(url.pathname + url.search);
  const cookie = encoder.encode(request.headers.get("cookie") || "");
  const clientIdentity = encoder.encode(request.headers.get("cf-connecting-ip") || "");
  const headers = FORWARDED_HEADERS.flatMap(name => {
    const value = request.headers.get(name);
    return value === null ? [] : [[encoder.encode(name), encoder.encode(value)]];
  });
  const contentLength = request.headers.get("content-length");
  if (contentLength !== null && Number(contentLength) > MAX_INCOMING_BODY_BYTES)
    throw new Error("request body too large");
  const body = request.method === "GET" || request.method === "HEAD"
    ? new Uint8Array()
    : new Uint8Array(await request.arrayBuffer());
  const headerBytes = headers.reduce((total, [name, value]) => total + 8 + name.length + value.length, 0);
  const total = 24 + method.length + target.length + body.length + cookie.length + clientIdentity.length + headerBytes;
  if (method.length === 0 || method.length > 16 || target.length === 0 ||
      target.length > MAX_INCOMING_TARGET_BYTES || body.length > MAX_INCOMING_BODY_BYTES ||
      cookie.length > MAX_INCOMING_COOKIE_BYTES || clientIdentity.length > 256 || headerBytes > MAX_INCOMING_HEADER_BYTES ||
      total > MAX_INCOMING_REQUEST_BYTES)
    throw new Error("request metadata too large");
  const encoded = new Uint8Array(total);
  const view = new DataView(encoded.buffer);
  view.setUint32(0, method.length, true);
  view.setUint32(4, target.length, true);
  view.setUint32(8, body.length, true);
  view.setUint32(12, cookie.length, true);
  view.setUint32(16, clientIdentity.length, true);
  view.setUint32(20, headers.length, true);
  let offset = 24;
  for (const part of [method, target, body, cookie, clientIdentity]) {
    encoded.set(part, offset);
    offset += part.length;
  }
  for (const [name, value] of headers) {
    view.setUint32(offset, name.length, true);
    view.setUint32(offset + 4, value.length, true);
    offset += 8;
    encoded.set(name, offset);
    offset += name.length;
    encoded.set(value, offset);
    offset += value.length;
  }
  return encoded;
}

const MAX_FETCH_REQUESTS = 64;
const MAX_FETCH_REQUEST_BYTES = 1024 * 1024;
const MAX_RESPONSE_SIZE = 8 * 1024 * 1024;
const MAX_RESPONSE_BYTES = 32 * 1024 * 1024;
const MAX_FETCH_CONCURRENCY = 2;

function decodeFetchRequests(bytes, decoder) {
  if (bytes.byteLength > MAX_FETCH_REQUEST_BYTES)
    throw new Error("fetch request bytes exceeded");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let offset = 0;
  const readU32 = () => {
    if (offset + 4 > bytes.byteLength) throw new Error("truncated fetch request");
    const value = view.getUint32(offset, true);
    offset += 4;
    return value;
  };
  const readBytes = (length) => {
    if (length > bytes.byteLength - offset) throw new Error("invalid fetch request length");
    const value = bytes.slice(offset, offset + length);
    offset += length;
    return value;
  };

  const requests = [];
  while (offset < bytes.byteLength) {
    if (requests.length >= MAX_FETCH_REQUESTS) throw new Error("too many fetch requests");
    const id = readU32();
    if (id !== requests.length) throw new Error("invalid fetch request ID");
    const maxResponseSize = readU32();
    const methodLen = readU32();
    const urlLen = readU32();
    const bodyLen = readU32();
    const headerCount = readU32();
    if (maxResponseSize > MAX_RESPONSE_SIZE) throw new Error("invalid response size limit");
    if (headerCount > 1024) throw new Error("too many fetch headers");
    const method = decoder.decode(readBytes(methodLen));
    const url = decoder.decode(readBytes(urlLen));
    const body = bodyLen === 0xffffffff ? undefined : readBytes(bodyLen);
    const headers = [];
    for (let i = 0; i < headerCount; i++) {
      const nameLen = readU32();
      const valueLen = readU32();
      headers.push([decoder.decode(readBytes(nameLen)), decoder.decode(readBytes(valueLen))]);
    }
    requests.push({ id, maxResponseSize, method, url, body, headers });
  }
  return requests;
}

async function readBoundedBody(response, limit) {
  const contentLength = response.headers.get("content-length");
  if (contentLength !== null && Number(contentLength) > limit)
    throw new Error("fetch response too large");
  if (!response.body) return new Uint8Array();

  const reader = response.body.getReader();
  const chunks = [];
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value.byteLength > limit - length) {
        await reader.cancel("fetch response too large");
        throw new Error("fetch response too large");
      }
      chunks.push(value);
      length += value.byteLength;
    }
  } finally {
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

async function runBounded(items, worker) {
  let next = 0;
  let firstError;
  const runners = Array.from(
    { length: Math.min(MAX_FETCH_CONCURRENCY, items.length) },
    async () => {
      while (next < items.length && !firstError) {
        const item = items[next++];
        try {
          await worker(item);
        } catch (error) {
          firstError ||= error;
        }
      }
    },
  );
  await Promise.all(runners);
  if (firstError) throw firstError;
}

async function provideFetchResults(wasm, requests) {
  let providedBytes = 0;
  await runBounded(requests, async (request) => {
    const response = await fetch(request.url, {
      method: request.method,
      headers: request.headers,
      body: request.body,
    });
    const body = await readBoundedBody(response, request.maxResponseSize);
    if (body.byteLength > MAX_RESPONSE_BYTES - providedBytes)
      throw new Error("total fetch response bytes exceeded");
    providedBytes += body.byteLength;
    const bodyPtr = wasm.alloc(body.byteLength);
    if (!bodyPtr && body.byteLength !== 0) throw new Error("WASM fetch result allocation failed");
    try {
      if (body.byteLength !== 0) new Uint8Array(wasm.memory.buffer).set(body, bodyPtr);
      const errorCode = wasm.provide_fetch_result(request.id, response.status, bodyPtr || 0, body.byteLength);
      if (errorCode !== 0) throw new Error(`WASM fetch result error ${errorCode}`);
    } finally {
      if (body.byteLength !== 0) wasm.dealloc(bodyPtr, body.byteLength);
    }
  });
}

// ── Main fetch handler ────────────────────────────────────────────────────────

async function handleRequest(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/_mer/resolve.js" && (request.method === "GET" || request.method === "HEAD"))
      return resolverResponse(request);

    // JS-handled API routes (wasm32 can't do network/clock)
    if (url.pathname === "/api/time") {
      const ts = Math.floor(Date.now() / 1000);
      return jsonResp({ timestamp: ts, unit: "unix_seconds", iso: new Date().toISOString() });
    }
    if (url.pathname === "/api/budget-ai" && request.method === "POST")
      return admitAi(request, env, (signal, admission) => handleBudgetAi(request, env, signal, admission));
    if (url.pathname === "/api/budget-suggestions" && request.method === "POST")
      return admitAi(request, env, (signal, admission) => handleBudgetSuggestions(request, env, signal, admission));

    // WASM-handled routes. Mutable state is isolated per request; only compilation is cached.
    let wasm;
    try {
      wasm = await createMerInstance();
      injectEnv(wasm, env);
    } catch (_) {
      return workerResponse("WASM initialization failed", { status: 500 });
    }
    const encoder = new TextEncoder();
    const decoder = new TextDecoder("utf-8", { fatal: true });
    let encoded;
    try {
      encoded = await encodeIncomingRequest(request, url, encoder);
    } catch (_) {
      return workerResponse("Request Too Large", { status: 413 });
    }

    const ptr = wasm.alloc(encoded.length);
    if (!ptr) return workerResponse("WASM alloc failed", { status: 500 });
    new Uint8Array(wasm.memory.buffer).set(encoded, ptr);

    // Phase 1: collect complete requests during a dry render. Snapshot all
    // application memory first so route side effects are not observed twice.
    const applicationState = new Uint8Array(wasm.memory.buffer).slice();
    try {
      const requestsPtr = wasm.collect_fetch_urls(ptr, encoded.length);
      const requestsLen = wasm.collect_urls_len();
      const requestBytes = new Uint8Array(wasm.memory.buffer, requestsPtr, requestsLen).slice();
      const expectedPtr = wasm.expected_state_ptr();
      const expectedLen = wasm.expected_state_len();
      const expectedState = new Uint8Array(wasm.memory.buffer, expectedPtr, expectedLen).slice();
      const collectError = wasm.fetch_protocol_error();
      if (collectError !== 0) throw new Error(`WASM fetch collection error ${collectError}`);

      new Uint8Array(wasm.memory.buffer, 0, applicationState.length).set(applicationState);
      const expectedCopyPtr = expectedState.length === 0 ? 0 : wasm.alloc(expectedState.length);
      if (expectedState.length !== 0 && !expectedCopyPtr)
        throw new Error("WASM expected-state allocation failed");
      try {
        if (expectedState.length !== 0)
          new Uint8Array(wasm.memory.buffer).set(expectedState, expectedCopyPtr);
        const restoreError = wasm.restore_expected_state(expectedCopyPtr || 0, expectedState.length);
        if (restoreError !== 0) throw new Error(`WASM expected-state restore error ${restoreError}`);
      } finally {
        if (expectedState.length !== 0) wasm.dealloc(expectedCopyPtr, expectedState.length);
      }

      // Phase 2: run bounded Worker fetches and provide results by unique ID.
      await provideFetchResults(wasm, decodeFetchRequests(requestBytes, decoder));
    } catch (_) {
      wasm.dealloc(ptr, encoded.length);
      return workerResponse("Fetch Bridge Error", { status: 502 });
    }

    // Phase 3: render once from the restored state with pre-fetched data in cache
    let resPtr;
    try {
      resPtr = wasm.handle(ptr, encoded.length);
    } catch (_) {
      wasm.dealloc(ptr, encoded.length);
      return workerResponse("Internal Server Error", { status: 500 });
    }
    wasm.dealloc(ptr, encoded.length);

    if (wasm.fetch_protocol_error() !== 0)
      return workerResponse("Fetch Bridge Error", { status: 502 });
    if (!resPtr) return workerResponse("Not Found", { status: 404 });

    try {
      const resLen = wasm.response_len();
      const decoded = decodeWorkerResponse(new Uint8Array(wasm.memory.buffer, resPtr, resLen), decoder);
      return workerResponse(decoded.body, decoded);
    } catch (_) {
      return workerResponse("Internal Server Error", { status: 500 });
    } finally {
      wasm.response_done();
    }
}

export default {
  async fetch(request, env, _ctx) {
    try {
      return await handleRequest(request, env);
    } catch (_) {
      return workerResponse("Internal Server Error", { status: 500 });
    }
  },
};

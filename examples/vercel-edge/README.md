# merjs on Vercel Edge

Deploy merjs as a Vercel Edge Function. The Zig framework compiles to
`wasm32-freestanding` and runs on Vercel's edge network — same binary
as Cloudflare Workers.

## Setup

1. Build the WASM binary:

```bash
cd ../..
zig build worker
# Generates both the Cloudflare and examples/vercel-edge/merjs.wasm outputs.
```

2. Deploy:

```bash
cd examples/vercel-edge
vercel
```

## How it works

- `api/index.js` creates a request-local WASM instance and uses the bounded
  binary request and versioned `MER1` response ABI.
- Incoming bodies are streamed with a 1 MiB cap, and `mer.fetch` calls use the
  bounded iterative collect/replay protocol.
- Responses are copied before `response_done()` releases WASM-owned memory.
- All application requests are rewritten to `/api` via `vercel.json`; existing
  files in a `public/` directory are served statically by Vercel first.

## Limitations

- Static assets are not embedded in WASM; place them in `public/` or a CDN.
- No hot reload in edge mode.
- WASM memory and Edge Function duration limits apply; fetch replay also has
  explicit request, response-byte, round, and 30-second deadline bounds.

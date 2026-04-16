# iframe-shared-storage

Tiny hub/client helper that lets you proxy `localStorage` and `indexedDB` (via [`idb-keyval`](https://github.com/jakearchibald/idb-keyval)) calls into a cross-origin iframe. The hub runs on a storage-friendly origin, while the client injects a hidden iframe, performs a readiness handshake, and then proxies storage calls through [`postmsg-rpc`](https://github.com/razorX2/postmsg-rpc).

## Highlights
- **Drop-in storage facade** – use the returned client just like `window.localStorage`, but every call is executed inside the hub origin.
- **Origin isolation** – keep your application origin locked down (COEP/COOP, CSP, etc.) while delegating storage access to a lightweight hub page.
- **Automatic readiness checks** – the client pings the iframe until the hub replies, enforcing a configurable timeout instead of hanging forever.
- **Optional diagnostics** – enable structured logging per-domain (`client`, `hub`, or `both`) to inspect RPC traffic when debugging.
- **Browser + bundler friendly** – ship `dist/browser.js` for `<script>` tags or import from the published package when bundling.

## How it works
1. **Hub** (`initHub`): expose `localStorage` and selected `idb-keyval` APIs to `postmsg-rpc`. Every method is wrapped with logging hooks and runs inside the iframe's origin.
2. **Client** (`constructClient`): either attach to an existing iframe or inject one that points at the hub URL. It keeps the iframe hidden, performs a handshake via `postMessage`, and only issues RPCs after the hub reports it is ready.
3. **Messaging options**: optional metadata is appended to every RPC so both sides can toggle logging without custom wire formats.

The repository also contains `client.html` / `hub.html` demo pages plus Playwright harnesses that emulate restrictive headers to ensure the handshake behaves under COEP/CORP variations.

## Installation
```bash
npm install iframe-shared-storage
```

### Building the standalone bundle
```bash
npm run build           # emits dist/index.js + dist/browser.js
```
Use `dist/browser.js` for `<script>` based integrations; it registers a global `IframeStorage` with `constructClient` and `initHub`.

## Quick start

### Hub page
```html
<!-- hub.html -->
<script src="/dist/browser.js"></script>
<script>
  IframeStorage.initHub();
</script>
```
Host this file on the origin that is allowed to use the storage APIs you care about.

### Client application
```ts
import { constructClient } from "iframe-shared-storage";

const storage = constructClient({
  iframe: {
    src: "https://storage-origin.example.com/hub.html",
    messagingOptions: { enableLog: "client" },
    iframeReadyTimeoutMs: 1500,
    methodCallTimeoutMs: 2000,
    methodCallRetries: 2,
  },
});

await storage.localStorage.setItem("foo", "bar");
const value = await storage.localStorage.getItem("foo");
await storage.indexedDBKeyval?.set("heavy", JSON.stringify({ ... }));
```

For non-bundled apps, the same API is available via the `IframeStorage` global that `dist/browser.js` defines:
```html
<script src="https://cdn.example.com/iframe-shared-storage/dist/browser.js"></script>
<script>
  const storage = IframeStorage.constructClient({ iframe: { src: "…" } });
</script>
```

## API

### `initHub(): void`
Call this once inside the hub iframe. The hub **must** have a parent window (i.e. it cannot run as a top-level page). It registers handlers for:
- `localStorage.setItem/getItem/removeItem/clear/key`
- `indexedDBKeyval.set/get/del`

### `constructClient(options: { iframe: … }): Client`
- Pass `{ iframe: { src: string } }` to inject a hidden iframe that points to your hub URL. The iframe receives an auto-generated `iframe-storage-hub` id.
- Pass `{ iframe: { id: string } }` to bind to an already-rendered `<iframe>` (useful when you control markup separately).
- `iframeReadyTimeoutMs` (default `1000`) caps how long the client will wait for the handshake before every RPC.
- `methodCallTimeoutMs` (default `1000`) caps how long each RPC waits for a reply before rejecting, so hung hubs fail fast instead of stalling tests forever.
- `methodCallRetries` (default `0`) retries RPCs that ended with a timeout. Each retry performs the same readiness check and timeout, so a `methodCallRetries` of 2 with `methodCallTimeoutMs` of 1000 can run for up to ~3 seconds before failing.
- `messagingOptions.enableLog` accepts `"client" | "hub" | "both"`. When set, both sides `console.log` contextual events (method names, payloads, and responses).

The returned object exposes:
```ts
type Client = {
  localStorage: {
    setItem(key, value): Promise<void>;
    getItem(key): Promise<string | null>;
    removeItem(key): Promise<void>;
    clear(): Promise<void>;
    key(index): Promise<string | null>;
  };
  indexedDBKeyval?: {
    set(key, value): Promise<void>;
    get(key): Promise<string | undefined>;
    del(key): Promise<void>;
  };
};
```

## Cross-origin requirements
- **Framing** – the hub page must be embeddable from the client origin. Avoid `X-Frame-Options: DENY` and ensure CSP `frame-ancestors` allows the client.
- **Embedder policies** – if the client enforces `Cross-Origin-Embedder-Policy`, make sure the hub responds with compatible headers (e.g. `COEP: require-corp` plus `Cross-Origin-Resource-Policy: cross-origin`). The Playwright suite (`npm run test:e2e`) exercises several combinations.
- **Handshake visibility** – the readiness ping uses `postMessage("*")` while the iframe is still loading `about:blank`, then switches to the actual origin. Keep that in mind if you monitor CSP reports.

## Local development
```bash
npm install
npm run build           # compile TypeScript + browser bundle
npm run build:watch     # concurrent module + browser watch (POSIX shells)
npm run serve:hub       # serve hub.html at http://127.0.0.1:5101
npm run serve:client    # serve client.html at http://127.0.0.1:5100
```
`client.html` is wired to load the production hub hosted on Vercel by default; uncomment the local URL in that file while iterating.

## Testing
- `npm run test` runs the Jest suite (unit tests for handshake, logging, timeout helpers, and a client↔hub integration sandbox).
- `npm run test:e2e` launches the Playwright scenario that spins up two Express servers with configurable COEP/CORP headers and validates the handshake logic.
- `npm run verify` or `npm run test:all` performs type checking, builds, unit tests, and e2e tests in sequence.

## Repository layout
- `src/` – TypeScript sources (client, hub, utilities, and tests).
- `dist/` – build artifacts consumed by npm and the in-browser demo.
- `client.html` / `hub.html` – runnable demo pair.
- `e2e/` – Playwright harness and Express servers for header/handshake testing.

Feel free to file issues or PRs if you need more storage methods exposed or would like to cover additional browser restrictions.

# Security policy

Security fixes apply to the latest release and `main`.

Report vulnerabilities through GitHub's private security advisory flow. Do not
attach real portraits, recordings, API keys, room tokens, AVTR authoring
projects, or unredacted logs.

## Trust boundaries

- The backend binds only to loopback and fails closed without Electron's random
  per-install authentication token, kept in a mode-0600 app-data file.
- HTTP and WebSocket requests require that token. State-changing cross-origin
  requests are rejected.
- Provider credentials, xAI OAuth state, and the LiveKit pilot token live in
  the OpenClam macOS Keychain namespace. Settings is write-only for secrets.
  xAI authentication has one explicit global mode (`api_key` or `oauth2`);
  requests never infer a mode from credential presence, combine modes, or
  silently fall back. The backend uses
  Security.framework directly, with authentication UI disabled for its
  queries, so values never enter process arguments, command streams, or files
  and an inaccessible item fails instead of hanging the server.
  The unsigned source-development host is an explicit exception: xAI OAuth
  and its LiveKit pilot token are held only in that backend process and are
  forgotten on restart. It never reads, rewrites, deletes, or broadens access
  to the signed release's protected items. Non-secret authentication mode may
  remain in a mode-0600 app-data file so Settings can explain the signed-out
  state after restart.
- The Security.framework migration uses versioned internal account names under
  the same service. It never touches legacy command-created items whose access
  list belongs to `/usr/bin/security`; users re-enter keys once after upgrade.
- The renderer cannot change the signed broker URL or expected LiveKit host,
  and HTTP redirects are rejected for credential-bearing broker calls.
- xAI OAuth runs in an explicitly labeled Grok Build compatibility mode. The
  signed source pins the public Grok Build client ID, its exact ten-scope set,
  and the audited upstream revision; production ignores environment-supplied
  client identities. OpenClam sends no Grok Build referrer, imports no Grok
  Build credential, and makes no partnership or OpenClam-registration claim.
  Release gates reject drift in those compatibility constants. Device
  authorization and refresh are pinned to `auth.x.ai`.
  OAuth LLM/search traffic is pinned to xAI's CLI inference origin, while
  voice and Imagine traffic is pinned to `api.x.ai`; token-bearing requests
  reject redirects. Refresh-token rotation is written atomically to Keychain,
  and concurrent refreshes are coalesced. If xAI restricts or withdraws the
  public Grok Build identity, OAuth fails closed; the separate API-key mode
  remains selectable and is never used as an automatic fallback.
- BYOK credentials are sent only for the selected call stages and never enter
  room, participant, or dispatch metadata.
- AVTR imports reject traversal, extra and duplicate paths, non-regular entries,
  links, oversized content, MIME/dimension mismatches, and altered hashes before
  atomic installation.
- Avatar Store is release-disabled in v1.0.1. Production code contains no
  catalog endpoint, hides the Settings entry, refuses every store IPC operation
  before network or cache access, and never exposes a stale remote catalog.
  The dormant generic engine still requires an explicit repository policy,
  strict redirect allowlisting, byte limits, SHA-256 verification, and the
  existing atomic AVTR validator. Direct local `.avtr` workflows are unchanged.
- Phone pairing is limited to explicit, short-lived OpenClaw codes. Bridge
  setup keys are passed only to the one-shot OpenClaw child process and are
  never stored by OpenClam. The packaged app does not include a LAN relay,
  EnConvo routing, System Audio capture, Apple Events automation, or
  Accessibility triggers.

A process already running as the same logged-in macOS user can inspect that
user's memory and files or tamper with an unsigned installation. That is outside
the local-app threat model. Published builds are always signed with the pinned
OpenClam Developer ID identity, Hardened Runtime enabled, notarized, and stapled.
The main app does not allow unsigned executable memory. The nested helper
entitlement permits it only because the bundled MLX Python worker emits local
inference pages for fully offline speech recognition; release QA executes a
known-phrase transcription from the signed app to prove this measured need.
The updater rejects a DMG or nested app unless its signature team, stapled
notarization ticket, Gatekeeper assessment, and macOS distribution policy checks
all pass before any installed file is replaced.

Before publishing:

```bash
npm run check
npm audit
npm run dist
```

The final command requires the `OpenClamStudioNotary` notarytool Keychain
profile and exact `THE GREAT LIONHEART PTE. LTD. (X7R8N6MMSU)` Developer ID
Application identity. It reruns tests, the dependency/privacy audits, and staged
Mach-O architecture/deployment-target checks; it cannot fall back to an
unsigned, unnotarized, or unchecked build.

Build only from the exact reviewed Git tree. Never publish Application Support
data, Keychain exports, `.env` files, provider keys, pilot tokens, model caches,
avatar sources, test recordings, `.venv`, `node_modules`, or local diagnostics.

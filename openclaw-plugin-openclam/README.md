# OpenClam channel for OpenClaw

This package makes OpenClam a first-class OpenClaw channel. A paired iPhone
sends text turns through the independent OpenClam bridge; this plugin receives
them over an outbound authenticated WebSocket and dispatches each turn through
OpenClaw's normal account binding and session pipeline.

The bridge is a relay and pairing boundary, not an AI server. It never receives
OpenClaw Gateway credentials, model-provider credentials, speech-provider
credentials, or local tool approvals. Legacy Connector v1 remains text-only;
new iOS builds may negotiate safe activity and private attachment extensions on
each turn without re-pairing.

## Compatibility

- OpenClaw `2026.7.1-2` or a compatible `2026.x` release
- Node.js 22 or newer
- The separately deployed `openclaw-bridge` Cloudflare Worker

This folder is an OpenClaw runtime plugin. It intentionally uses
`openclaw.plugin.json`; it is not a Codex plugin bundle.

## Install and pair

Do these steps on the machine that runs the OpenClaw Gateway. The package does
not need any inbound port because it connects out to the bridge.

1. From the integration repository root, build and install the package:

   ```bash
   npm --prefix ./openclaw-plugin-openclam run build
   openclaw plugins install ./openclaw-plugin-openclam
   ```

   The repository includes compiled `dist/` entry points. The explicit build
   keeps them synchronized before a local-path installation. A published or
   packed package runs the same build automatically during `prepack`.

2. Put the bridge bootstrap token in the environment for this one pairing
   command. Do not place it in command-line arguments:

   ```bash
   export OPENCLAM_BRIDGE_BOOTSTRAP_TOKEN='replace-with-the-worker-secret'
   ```

3. Create a one-time code. With no `--agent` or `--map`, all configured
   OpenClaw agents (up to 32) are advertised. `--bridge-url` must be the HTTPS
   root origin, with no path, query, fragment, or embedded credentials:

   ```bash
   openclaw openclam pair --bridge-url https://openclam-bridge.example.workers.dev
   ```

4. In OpenClam on the iPhone, choose **Connect to OpenClaw** and enter the
   displayed `OC-XXXX-XXXX-XXXX` code before it expires.

5. Restart the Gateway after the new channel config has been written. This
   repository does not install, configure, or restart the user's live Gateway
   automatically.

To expose only selected agents:

```bash
openclaw openclam pair \
  --bridge-url https://openclam-bridge.example.workers.dev \
  --agent main \
  --map ara=research
```

`--agent main` uses `main` as both the OpenClam account ID and OpenClaw agent
ID. `--map ara=research` exposes account `ara` and binds it to agent
`research`. Account IDs are normalized with OpenClaw's account rules before
they are advertised or stored: letters become lowercase and separators such as
`.` or `:` become `-`. The avatar label remains the agent identity name, so an
account and agent ID of `ara` can still display as `Ara`. The command writes
standard OpenClaw bindings of this form:

```json
{
  "agentId": "research",
  "match": { "channel": "openclam", "accountId": "ara" }
}
```

The bridge's advertised `agentId` is metadata. It never overrides OpenClaw's
binding resolver. If a binding changes after pairing, turns fail closed and the
operator creates a fresh pairing so the iPhone receives accurate metadata.

## Replace or rotate a pairing

`--replace` creates a new adapter connection and writes its private local
credential first. It must then receive a successful revocation response for
the old bridge connection before it commits the new channel config or prints
the new code:

```bash
openclaw openclam pair \
  --bridge-url https://openclam-bridge.example.workers.dev \
  --replace
```

If new connection creation or local credential/state writing fails, the old
connection and config are left untouched and cleanup of the new connector is
attempted. If old revocation fails or has no positive response, the new config
is not committed, its connector is revoked best-effort, and the command fails
without printing a pairing code.

A successful replacement has planned downtime. It starts when the command
revokes the old connector and ends only after the command commits the new
config, the displayed code is redeemed on the iPhone, and the Gateway is
restarted. Do not run `--replace` during an active conversation, and complete
those steps promptly. Staged zero-downtime replacement is not supported in
this version. If the final atomic config write fails after old revocation, the
command fails closed and the operator must run pairing again.

## Safe status

```bash
openclaw openclam status
```

Status shows connection and account metadata but never prints the adapter
credential or bridge bootstrap token.

## Runtime behavior

- One bridge connection may advertise 1–32 OpenClam accounts.
- Each `accountId` is routed with standard OpenClaw account-scoped bindings.
- A stable OpenClam conversation ID maps to a stable OpenClaw session route.
- Partial replies are sent as cumulative `assistant.delta` snapshots.
- Updated clients receive a single coalesced activity card using fixed safe
  categories such as Thinking, Searching, Editing, and Preparing files. The
  adapter never forwards plan text, reasoning, tool names, arguments, output,
  commands, or local paths as progress.
- Generated media is resolved only with OpenClaw's official agent-scoped
  outbound-media helpers. The plugin advertises channel media support, uploads
  validated files privately to the bridge, waits for durable attachment
  metadata receipts, and sends metadata before the final reply. It never reads
  an arbitrary filesystem path or sends a local source path/URL to iOS.
- Attachment delivery is capped at eight files, 32 MiB per file, and 64 MiB per
  turn. Sensitive live-only media fails closed and is never persisted as a
  normal OpenClam attachment. Media-only turns receive a neutral caption.
- A legacy client that did not advertise capabilities receives only established
  frame kinds and a fixed upgrade notice when generated media is omitted.
- Cumulative snapshots are coalesced and capped per turn so a slow phone cannot
  create an unbounded adapter or bridge backlog. Terminal replies take priority.
- Every admitted turn ends with exactly one `assistant.completed` or
  `turn.error` durably confirmed by the bridge. Until the strict
  `relay.persisted` receipt arrives, the adapter retains and replays the exact
  encoded terminal frame; a socket write alone is never treated as delivery.
- Cancellation is idempotent and aborts the underlying OpenClaw run.
- Only one active turn is allowed per conversation.
- If the socket closes before a terminal receipt, an in-process reconnect
  replays the exact terminal bytes without running the agent again. Private
  durable state contains only a transcript-free recovery marker. After a
  process restart, that marker reconciles the turn with one safe error; the
  bridge suppresses it when the authoritative final was already persisted.
  Recovery markers expire locally after 15 minutes so retired Worker state
  cannot poison a still-valid connector.
- Revoked or expired connector responses stop reconnecting and abort and await
  active OpenClaw runs before the channel shuts down.
- Paired text is not marked as command-authorized. It follows the agent's normal
  tool policy instead of receiving implicit channel-command authority.
- Adapter sequence state is persisted with mode `0600`. If that file is lost
  or corrupt, create a fresh pairing; resetting sequence numbers on an existing
  connection is intentionally rejected by the bridge.
- Reconnect relies on the bridge's durable replay of unacknowledged frames. The
  adapter acknowledges every forwarded non-ack frame and never acknowledges an
  ack.
- Logs contain event names, status codes, durations, and opaque IDs only. They
  do not contain user or assistant text.

## Files written by pairing

By default, pairing writes two private files beneath:

```text
~/.openclaw/credentials/openclam/<connectionId>/
  adapter-token
  adapter-state.json
```

The token is returned by the bridge exactly once. The state file contains only
sequence cursors, opaque turn identifiers, and safe recovery status; it contains
no transcript text.
Use `--credential-directory <path>` when the OpenClaw state directory is not
the desired credential location.

## Development

```bash
npm install
npm run typecheck
npm test
npm pack --dry-run
```

Tests use mocked bridge sockets, runtime dispatch, configuration mutation, and
credential storage. They do not connect to or modify a live OpenClaw Gateway.
The release archive contains only compiled runtime files, the OpenClaw manifest,
package metadata, and this README; TypeScript sources, tests, and development
configuration are excluded.

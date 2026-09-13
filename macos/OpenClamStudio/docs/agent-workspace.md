# OpenClam agent workspace

OpenClam now has a persistent **Tasks** workspace backed by the official Codex
app-server. It is separate from the short, ephemeral `codex exec` requests used
by the existing ChatGPT chat lane. OpenClaw chat, Live Talk, Tia and Performer
remain available.

Open **Tasks** from the Chat sidebar or **Tasks · Agent workspace…** from Tia's
context menu. The development app also accepts `--tasks`.

## Why this architecture

The supplied Pragmatic Engineer interview argues for separating the product UI
from an agent engine that owns tools, permissions, context and execution. The
implementation follows that boundary instead of recreating an agent with
hardcoded keyword triggers. Pi was not used or consulted.

The [official app-server interface](https://learn.chatgpt.com/docs/app-server)
provides the actual Codex task engine. Model quality, available tools and account
entitlements still matter; a UI cannot reproduce unavailable hosted features.

## Working capabilities

| Capability | Implementation |
| --- | --- |
| Multi-step work | Real model/tool loop: commands, file editing, tests, web search and available engine tools |
| Persistent context | Start and resume native Codex threads; OpenClam owns a separate task registry |
| Projects | Native folder picker or a fresh workspace; per-task permission choices |
| Follow-ups | `turn/steer` changes direction during a running turn; later messages continue the same thread |
| Stop | Interrupt the current turn; no hidden retry or alternate-agent fallback |
| Background tasks | Tasks continue while their UI window is closed; at most three run concurrently |
| Recovery | After engine/app restart, retain history and mark unfinished work interrupted; resume explicitly |
| Approvals | Command/file approvals, scoped permission grants and structured user questions |
| Evidence | Live progress, plans, tool output, command exit status, file changes, final response |
| Files | Attach files/images, browse the task folder, preview text and download outputs |
| App previews | Sandboxed HTML preview; localhost app links open in a separate temporary browser session |
| Review | Engine review constrained to this task's folder and work |
| Branch conversation | Fork completed conversation history in the same project directory |
| Models | Full paginated engine catalog, including additional hidden models and supported reasoning settings |
| Skills and tools | Discover configured skills and MCP connections; invoke skills through the conversation |
| Task organization | Rename, archive and restore locally without deleting the engine's history |

Conversation branching shares files. It is not a Git worktree and should not be
used as filesystem isolation for conflicting edits.

## Setup and scope

The task engine selects the newest installed official Codex runtime from the
Codex/ChatGPT app or CLI, and uses its existing account
authentication. OpenClam does not read or copy OAuth tokens. Sign-in stays in the
existing OpenClam OpenAI account settings / Codex login flow. The engine reports
the models it can run; OpenClam does not silently retry an explicit model choice
with a different model. Configured skills and MCP services may require their own
dependencies or sign-in.

### Models and permissions

The model picker requests every catalog page with `includeHidden: true`. Normal
models appear first; models hidden by the engine's default picker appear under
**Additional engine models**, with the engine's own descriptions. This is the
connected account/engine catalog, not every model sold by every API provider.
An explicit saved model remains selected even if a later catalog omits it; a
failed model request is never silently sent to another model.

Permissions are saved per task and can be changed between turns:

| Choice | Engine behavior |
| --- | --- |
| Ask for approval | Project-write sandbox; user reviews requests for additional access |
| Approve for me | Project-write sandbox; Codex's risk-based `auto_review` handles approval requests |
| Always allow · project | `never` approval policy inside the project sandbox; blocked access stays blocked |
| Full access | Unrestricted filesystem/network execution with no approval prompts |
| Read only | Read-only sandbox; user reviews requests for additional access |

New tasks start with **Ask for approval**. Choosing Full access is explicit; it
is not inherited by unrelated new tasks. All five choices apply to thread
start/resume, subsequent turns and conversation branches. Running turns keep
their current permissions; stop or finish before changing them. Existing task
registries migrate without escalating their access.

Approval cards also offer **Allow for this session** when supported by the
engine: the engine keeps the session-scoped command/file approval, or exactly
the requested permission grant. This does not create a permanent global rule.
Auto review may deny an action; it is not an unconditional accept button.

This adds the local agent core to the macOS development app. It does **not**
claim feature-for-feature parity with the entire Codex product:

- Codex-hosted cloud jobs, mobile handoff, private app services and their account
  entitlements are not recreated.
- The existing OpenClaw connection still owns Chat/Live Talk; this release does
  not route those voice conversations through the new Tasks thread.
- The new task UI is not yet a native iPhone workspace.
- Automatic Git worktree management, recurring scheduled tasks, and a connector
  installation/sign-in UI are not implemented here.
- MCP elicitation flows requiring external forms are declined by this client;
  command approvals and agent questions are supported.

These are product integrations beyond the local engine, not things to promise
based on the interview or a successful coding demo.

## Boundaries and resource use

- Only tasks in OpenClam's registry can be addressed. Other Codex conversations
  are not automatically listed or imported.
- All HTTP routes retain Studio's loopback authentication, origin checks,
  no-store responses and security headers. There is no arbitrary RPC proxy.
- Native actions check window, main frame, origin and exact document path.
- Approval IDs are single-use and bound to a task, turn and engine generation.
  Unsupported server requests fail closed. No action is automatically replayed
  after an uncertain acknowledgement.
- File previews resolve paths against the task project and reject escapes.
  User HTML is downloaded as data; inline previews use an opaque sandbox with
  network and forms disabled. Local app previews have no Studio token/preload.
- Display output is bounded; encrypted/private reasoning is not projected.
  SQLite persists a bounded event journal, and reconnect sends a fresh snapshot.
- A single lazy app-server process serves the workspace. It shuts down after
  three minutes without UI activity when no task is running. Closing the task
  window destroys that renderer; active work is kept in the backend.
- `agent-workspace/` is private runtime data, ignored by Git, rejected by the
  public-source audit and excluded from the packaged web/server allowlists.

## Verification

The initial integration was exercised against Codex CLI 0.149.1 over stdio, including
account/model discovery, real file edits and test execution. A desktop task
created a tip calculator, caught a floating-point failure, fixed it, reran two
tests successfully and wrote a report. The task survived restarting OpenClam.
The UI showed configured skills and MCP servers.

The model/permission update was verified with the installed official 0.153.4
runtime: GPT-6-Astra completed a real request, the full catalog returned eight
models, and all requested approval/access combinations were accepted by the
engine. Existing-thread changes were verified using `thread/settings/update`,
including switching to automatic review and receiving another Astra reply.
This endpoint requires the app-server experimental API, which the connection
explicitly enables. The runtime version is discovered, not hardcoded.

Automated coverage includes runtime selection, catalog pagination, policy
mapping across start/resume/turn/fork, legacy registry migration, rejecting
settings changes on active turns, session-scoped grants, protocol interleaving, persistent state, steering,
restart recovery, approval ownership/reuse/expiration, permission scope,
structured questions, unknown requests, file traversal and symlink escapes,
attachment ownership, history deltas, concurrent thread loading, local HTTP
authentication, cross-origin rejection and native-window boundaries.

Run from the Studio directory:

```sh
.venv/bin/python -m unittest tests.test_agent_workspace tests.test_agent_routes -v
node qa/agent_workspace_qa.cjs
npm run check:syntax
```

The full Python suite passed with 1,409 tests during this integration. Desktop
shell, renderer, release-security and public-source audits also passed. The
Tasks workspace is included in macOS 1.0.33; its release uses the mandatory
signing, notarization and packaged-runtime checks.

# Hermes

Tonycast embeds [Hermes](https://hermes-agent.nousresearch.com/docs) as a real client: a chat window
that talks to the same `hermes acp` agent the desktop app does, over the
[Agent Client Protocol](https://agentclientprotocol.com). `Features/Hermes/` owns the process, the
session and the window. It knows nothing about the AI providers in [ai.md](ai.md), which is a
different thing entirely — those are direct model calls; this is a full agent with tools, skills and
memory, running on a machine you choose.

## Invariants

- **One long-lived process, never one per prompt.** `ACPClient` starts `hermes acp` once and keeps it
  for the app's lifetime. Cold start costs seconds and every turn carries the agent's full system
  prompt, so respawning per prompt is the expensive failure mode. `ACPSessionManager.connect()` is
  idempotent for the same reason.
- **The client is an `actor`, and for a measured reason.** One turn pushes hundreds of notifications
  (token chunks, thinking, tool progress). None of that traffic may hop through the main thread on
  its way in, so the wire lives off-main and the UI observes a `@MainActor` projection.
- **`ACPClient` is the process layer, and ACP gets its own streaming client.** The MCP transport's
  stdio shape is shared deliberately; MCP's *client* is not reused for ACP. Two protocols, one
  process-layer idiom.
- **A session is filed in Hermes' own sidebar by its cwd, and Home means an empty one.** Hermes'
  backend files a session whose cwd is the user's home directory under **Home**, but its frontend
  computes a project id that has no node, so the row renders in neither a project lane nor Home and
  is reachable only by search. Empty cwd is the single value both sides agree is Home. That is why
  `HermesSettings.sessionDirectory` defaults to `""` and must stay empty by default —
  `Tests/hermes-placement-test.swift` pins it.
- **The process launch directory is a different value and never leaks into the session cwd.**
  `Process` cannot start in a directory that does not exist, so `launchDirectory` always resolves to
  a real one and falls back to home. The session wants the empty string. Splitting the two is
  load-bearing: sending the launch directory as the session cwd is exactly the bug the empty default
  exists to prevent.
- **A connection is a launch recipe, not a network client.** `HermesConnection` holds a command and
  its arguments — `hermes acp` for this Mac, `ssh -T hermes ~/.local/bin/hermes acp` for the
  homelab VM. Every layer above it is host-agnostic because the wire is identical either way. `-T`
  is not optional: a pseudo-terminal would rewrite newlines and destroy the newline-delimited
  framing.
- **Session ids are remembered per connection.** A session id only exists in the Hermes instance
  that minted it, so `savedSessionID`/`savedSessionCwd` are keyed by connection id. Handing the Mac's
  id to the VM would fail every reattach after a host switch.
- **The permission broker only ever *narrows*.** `ACPPermissionBroker` may remove options the agent
  offered; it may never add one, and it may never widen a grant. A destructive-classified command is
  never offered a session-scoped option, the default is Deny, and an unrecognised command fails safe
  rather than through. The classification reads the **command line**, never prose.
- **A prompt carries paths, never bytes.** `ACPAttachment` holds a path and sends a `resource_link`
  block; the agent resolves the URI and reads the file itself. That keeps a large file out of
  Tonycast's memory and off the pipe, and it is why attachments survive a re-render for free. The URI
  is built by `URL`, not by hand — a `#` in a filename must not truncate it or invent a query.
- **The token gauge mirrors Hermes' own formatter, deliberately.** `HermesUsageFormat` ports
  `@hermes/shared`'s `compactNumber` and the statusbar's label format, thresholds included, so
  `1048576` reads `1M` and never `1.0M`. Where the desktop and a local improvement would disagree —
  a bar whose cells round on the raw percent while the label rounds up — **parity wins**, because
  "the same as Hermes" is the whole requirement.
- **The measured count wins over the estimate.** A mid-turn `usage_update` carries only a rough
  estimate of request pressure; the prompt response's `usage` block carries the provider's measured
  input tokens. The gauge shows the estimate with a `~` and drops it once the measurement arrives.
- **Tonycast presents its own dialogs here too.** A permission prompt is
  `HermesPermissionSheet` inside the window, not `NSAlert`. See the non-negotiables in
  [../standards.md](../standards.md).
- **Hermes Desktop's own bugs are routed around, never patched.** The Home-placement fix lives in
  Tonycast's cwd handling; no file under `~/.hermes/hermes-agent/` is edited. That rule is what keeps
  the embedded client upgradeable.

## Where things are

| Path | Holds |
| --- | --- |
| `Service/ACPProtocol.swift` | JSON-RPC 2.0 framing: one message per line |
| `Service/ACPMessage.swift` | The typed payloads this client sends and answers |
| `Service/ACPClient.swift` | The process, the handshake, request bookkeeping, timeouts |
| `Service/ACPFrameWriter.swift` | Serial, off-actor writes |
| `Service/ACPSessionManager.swift` | Session lifecycle, transcript, the one usage reading |
| `Service/ACPPermissionBroker.swift` | Which permission options may be offered |
| `Model/HermesConnection.swift` | The Mac/VM launch recipes |
| `Model/ACPAttachment.swift` | A picked file, and its `resource_link` block |
| `Model/HermesUsageFormat.swift` | Hermes' number formatting, restated |
| `Settings/HermesSettings.swift` | Connection, directories, per-host session memory |
| `UI/` | The window, transcript, composer, attach controls, permission sheet |

## The wire

Request methods the client sends: `initialize`, `session/new`, `session/load`, `session/cancel`,
`session/set_mode`, `session/set_model` and `session/prompt`. The agent pushes `session/update`
notifications (`agent_message_chunk`, `agent_thought_chunk`, `tool_call`, `tool_call_update`, `plan`,
`usage_update`) and may raise `session/request_permission`, which Tonycast answers with a
`selected`/`cancelled` outcome. Field names are the wire names from `acp/schema.py` — never guessed,
always read from source.

## Trying it

Open the palette, type `Hermes`, press Enter. The window connects on show and is warm afterwards:
closing hides it rather than destroying the process or the transcript. Pick the host from the menu
beside **New Session**; switching tears down the old process and starts a fresh session on the new
one, because a session belongs to the instance that minted it.

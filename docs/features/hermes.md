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
- **The transcript renders a reply as markdown, and a user message verbatim.** The agent writes
  prose — headings, lists, tables, fenced code — and `MarkdownView`/`MarkdownBlock` (shared with
  `Features/AI/`, which parses the same shape) is what turns it into a block tree. What the user typed
  is echoed back as plain text on purpose: a `*` or a `#` they meant literally must survive the round
  trip. See [ai.md](ai.md) for the parser's own invariants.
- **The sidebar's session list comes from the host's session store, and the wire is not used for it.**
  `session/list` reports only the sessions Hermes created over ACP, which is a small fraction of what
  Hermes holds — so it is no longer the sidebar's source. It remains implemented and tested because it
  is the protocol's own answer, and `session/load` is still how a continuable session is opened.
- **The project and session reads run on the connected host, never on this Mac.** The window can be
  attached to the VM, and which projects and sessions exist is a property of the host holding them. Each
  read therefore travels the connection's own launch recipe — the interpreter locally, the same
  interpreter over `ssh` for the VM — with the script on **stdin**, so no path is ever quoted into a
  shell command line. This is a second launch recipe beside `command`/`arguments`, which describe the
  long-lived `hermes acp` wire and would be the wrong thing to reuse. `HermesHostScript` owns that
  launch once for both readers.
- **`mode=ro` is tried first and a plain connection second, and the probe query is load-bearing.**
  Hermes keeps `projects.db` in WAL mode, and a read-only connection to a WAL database whose `-shm`
  file is absent fails with "unable to open database file" — the file exists only while something holds
  the database open, so the listing would work while Hermes ran and fail when it did not. Reading the
  file at all is a deliberate reach into another application's store, taken because the projects are
  not reachable any other way; the reader only ever issues two SELECTs and writes nothing.
- **A new session in a project opens in that project's primary folder, and a folder that is not on
  disk is refused.** A session's cwd is fixed when it is created, so one created against a missing path
  is wrong for its whole life; a project with no usable folder starts a Home session instead. This is
  the same rule that keeps the default session directory empty (below), applied per project.
  **The host resolves that folder, not this Mac** — `HermesWorkspaceReader`'s script runs
  `os.path.isdir` where the directory actually is, because every VM path is absent from here.
- **The sidebar lists one project at a time, and Home is the default.** Hermes can hold dozens of
  projects, and one section per project makes the column mostly empty headers; the picker selects one
  and its sessions sit beneath it. Home is an entry in that picker even when it holds nothing, because
  it is where a launcher chat belongs — a fresh window opens there, and the picker must not silently
  land on a project. Each entry carries its session count, so an empty project says so before it is
  chosen.
- **There is one New Session control, and it is the `+` beside the project name.** It starts a session
  in the listed project's own folder — the folder the host resolved — and for Home it starts one with
  an empty cwd. It sits *beside* the picker rather than inside it, because a control in a `Menu`'s
  label opens the menu instead of running. Nothing else offers a New Session: not the read-only
  notice, and not the window header, since that control belongs to the project it names.
- **The column fades only its bottom edge, and only while content is hidden below.** It uses
  `overflowFade()`, not `edgeDissolve()`: the latter masks the top as well, and its fade band is the
  palette bar's height, which over this plain header covers the first row and leaves it dimmed while
  the list rests at the top. A row is shaded only when it is the open session or under the pointer —
  never because it happens to be first.
- **The sidebar lists every session Hermes files under a project, and marks the ones it cannot
  continue.** `session/list` is *not* the source: Hermes scopes it to the sessions it created over ACP,
  so a project full of work done in the desktop app, the web UI or a cron job read as **empty** — the
  reported symptom. Worse, `session/load` answers a non-ACP id with an empty **success** rather than an
  error, so listing them without this would open a blank window. `HermesSessionReader` therefore reads
  the sessions table on the host, and each row's `source` decides its treatment: an `acp` row opens and
  continues, anything else opens **read-only**, with the composer replaced by an explanation naming
  where the session came from. `subagent` and `oneshot` are excluded — machine traffic, not work a
  person looks for.
- **A session is filed under a project by its cwd *or* its git root.** A project holds folders rather
  than one checkout, and Hermes files a session under whichever of the two matches, so matching the cwd
  alone leaves a session run in the project's second folder ungrouped. The deeper of the two matches
  wins, so a session inside a nested project stays with the nested one. `Tests/hermes-workspace-test.swift`
  pins both halves.
- **The sidebar is re-read on a warm connect, when the window comes forward, and by a Refresh button.**
  Hermes' own app can create a session in a project while this window sits hidden, and nothing on the
  wire announces it — `session/list` only reports what ACP created. So `connect()` reads the store on
  its already-ready path instead of returning at the guard, `HermesWindowController.windowDidBecomeKey`
  asks for a refresh, and the header carries a **Refresh** button.
  **The button is the part that actually keeps the list current**, because the panel is a
  `nonactivatingPanel` that floats above other apps: while you type in Hermes' own window this one
  never becomes key, so neither of the automatic paths can fire. Do not remove it as redundant — it is
  the only way to see a session created elsewhere without restarting Tonycast.
- **A session another surface created cannot be reopened here, so its work is carried instead.**
  Hermes refuses to restore any row whose `source` is not `acp` (`acp_adapter/session.py`, in
  `_restore`), and **every** ACP path funnels through that check — `load`, `resume`, and even `fork`,
  which calls `get_session` first. Verified by reading the adapter and by testing the wire: a relaxed
  check loaded a desktop session and ran a real turn, so the gate is the only obstacle, and it is
  Hermes' deliberate restriction rather than a gap in this client.
  **Do not patch Hermes' installed source for this.** `session/foreign.*` exists for exactly this job
  but is narrowed to Claude Code and Codex folders, and a patch is lost on the next Hermes update.
  `HermesSessionHandoff` is the supported route: **Continue** in the read-only notice starts a new
  session **in the project the old one was filed under** and hands the agent the conversation as
  context, so the work continues in a session this client can own. The original stays read-only and
  untouched, and both surfaces can hold their own thread of the same work without writing over each
  other. Tool and thinking items are dropped from the handover — they were 186 kB of one 220 kB
  session and none of its meaning, while the exchange itself was 33 kB — and the bound keeps the
  newest turns, which is what a continuation needs.
- **`send` returns when the agent has taken the message, and the turn runs detached.** `client.prompt`
  answers only at `end_turn`, which for real work is minutes, so awaiting it inside `send` meant the
  composer could not clear its draft until the turn finished — the sent text sat in the input field the
  whole time and read as a failed send. `send` now appends the message, marks the turn active and
  dispatches `runTurn` in a `Task`, returning on acceptance; the reply still arrives through the same
  event stream. Acceptance is what the caller needs, and a send that cannot start still reports false,
  so a lost connection never discards what was typed. **One turn at a time is enforced in `send`**, not
  only by the composer hiding the button, because nothing else now stops a second prompt while the
  first is detached.
- **The sidebar never reports a failure by emptying itself.** A host that cannot answer leaves the pane
  showing what it had, and a session that fails to open keeps its row and puts the reason next to the
  composer. An empty list reads as "no sessions", which is a different and wrong claim.
- **A session is filed under its longest matching project folder.** The rule is Hermes' own, and the
  failure mode of getting it wrong is quiet: sessions simply appear under the wrong project. The match
  walks path components rather than prefixes, so `/Users/tony/github` is not inside `/Users/tony/git`.
  `Tests/hermes-workspace-test.swift` pins both halves.
- **An image attachment only works when the agent's model can see.** Verified from the request dump:
  Tonycast builds the correct `data:image/png;base64,…` block and Hermes turns the link into it, so
  the client side is sound. What fails is downstream — a text-only model answers HTTP 500 (Ollama
  Cloud: `deepseek-v4.1-flash` 500s on any image while `glm-5.3-flash` accepts and correctly
  describes the same bytes). A dead-end here is a provider/model fact, not a Tonycast bug: check the
  agent's configured model before suspecting the attachment path, and give the agent a fallback.
- **The token gauge mirrors Hermes' own formatter, deliberately.** `HermesUsageFormat` ports
  `@hermes/shared`'s `compactNumber` and the statusbar's label format, thresholds included, so
  `1048576` reads `1M` and never `1.0M`. Where the desktop and a local improvement would disagree —
  a bar whose cells round on the raw percent while the label rounds up — **parity wins**, because
  "the same as Hermes" is the whole requirement.
- **The measured count wins over the estimate.** A mid-turn `usage_update` carries only a rough
  estimate of request pressure; the prompt response's `usage` block carries the provider's measured
  input tokens. The gauge shows the estimate with a `~` and drops it once the measurement arrives.
- **The gauge rides inline in the composer row, and reserves its widest reading.** It sits between the
  text field and Send, right-aligned, rather than on a row of its own below the composer — that
  orphaned line was the thing to remove. Because the row is now shared, the gauge cannot resize as it
  ticks: `used` climbs from `9.9k` to `10.0k` mid-turn, and a self-sizing label would change the
  row's width and drag the text field's caret while the user is typing.
  `HermesUsageFormat.widestContextLabel(size:)` derives the reserved width from the live context
  window, so the slot tracks a 1M window or a 128k one. Do not replace it with a literal —
  `Tests/hermes-features-test.swift` sweeps every reading across a range of windows to prove the
  reservation holds, which a hardcoded string would silently fail once the window changed.
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
| `Service/ACPSessionManager.swift` | Session lifecycle, transcript, sidebar state, the one usage reading |
| `Service/ACPPermissionBroker.swift` | Which permission options may be offered |
| `Service/HermesHostScript.swift` | Runs a read-only script on the connected host |
| `Service/HermesWorkspaceReader.swift` | Reads the connected host's own project list |
| `Service/HermesSessionReader.swift` | Reads every source's sessions for the sidebar |
| `Service/HermesTranscriptReader.swift` | Reads one session ACP cannot reopen, read-only |
| `Model/HermesConnection.swift` | The Mac/VM launch recipes |
| `Model/HermesWorkspace.swift` | A project, and the path rules a session is filed by |
| `Model/HermesSessionSummary.swift` | One session row, and the host store's decode |
| `Model/HermesSessionHandoff.swift` | Carries a foreign session's conversation forward |
| `Model/HermesSidebarSection.swift` | Projects plus their sessions, grouped |
| `Model/ACPAttachment.swift` | A picked file, and its `resource_link` block |
| `Model/HermesUsageFormat.swift` | Hermes' number formatting, restated |
| `Settings/HermesSettings.swift` | Connection, directories, per-host session memory |
| `UI/` | The window, sidebar, transcript, composer, attach controls, permission sheet |

## The wire

Request methods the client sends: `initialize`, `session/new`, `session/load`, `session/list`,
`session/cancel`, `session/set_mode`, `session/set_model` and `session/prompt`. The agent pushes
`session/update` notifications (`agent_message_chunk`, `agent_thought_chunk`, `tool_call`,
`tool_call_update`, `plan`, `usage_update`, `available_commands_update`) and may raise
`session/request_permission`, which Tonycast answers with a
`selected`/`cancelled` outcome. Field names are the wire names from `acp/schema.py` — never guessed,
always read from source.

`session/list` pages at 50 rows and resumes after a `cursor` that is the last `sessionId` returned.
The client sends no cursor, so it reads the first page only — the agent's own ordering is
newest-first, which is the ordering the sidebar shows.

## Trying it

Open the palette, type `Hermes`, press Enter. The window connects on show and is warm afterwards:
closing hides it rather than destroying the process or the transcript. The left column opens on
**Home** with its sessions listed; the picker at its top switches to any project on the connected host,
whose sessions then replace them, and the session count in each entry says which are empty. The `+`
beside that picker starts a session in the listed project's folder, or under Home. Selecting a session
replays it, and one Hermes created elsewhere opens read-only with a **Continue…** that carries it
into a new session in the same project. **Refresh** in the window's header
re-reads the projects and sessions from the connected host, which is how a session created in Hermes'
own app appears here without a restart. Pick the host from the menu in the window's header; switching
tears down the old process, clears the sidebar, and starts a fresh session on the new one, because a
session and its project list both belong to the instance that minted them.

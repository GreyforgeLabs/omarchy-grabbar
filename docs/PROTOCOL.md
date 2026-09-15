# Backend ↔ shell protocol (version 1)

The native backend listens on a private Unix socket,
`$XDG_RUNTIME_DIR/grabbar/<HYPRLAND_INSTANCE_SIGNATURE>/backend.sock`
(directory and socket mode `0700`/`0600`). The shell service, the CLI and the
tests connect to it. Same-user clients are not treated as a security boundary
(spec §6.4); the protocol still validates every field it acts on.

## Wire format

One message per line. Fields are tab-separated; the first field is the
message type, the rest are `key=value`. Values are percent-encoded: control
characters, `%`, tab and newline become `%XX`. Lines longer than 8192 bytes
or an input buffer over 32 KiB drop the client. Output backlog over 256 KiB
drops the client too (a stuck reader must not stall the compositor).

Encoders/decoders that must agree: `native/grabbar/backend.cpp`
(`grabbarEncode`), `GrabbarModel.js` (`encodeField`),
`helpers/grabbar_backend.py` (`encode`). `tests/unit/test_protocol.py` and
`tests/unit/test_model.js` pin the format.

## Identity

- **token** — `g<epoch>-<n>`: issued per live window the first time the
  backend sees it. The epoch is the backend start time; `n` increases
  monotonically. A reused compositor address for a different window gets a
  new token. Every action names a token; `resolve()` re-checks that the
  token still maps to the same mapped window (`m_stableID`) and otherwise
  answers **stale**. Nothing ever falls back to the focused window.
- **requestId** — caller-chosen, `[A-Za-z][A-Za-z0-9_-]{0,63}`. Results
  echo it. Minimize requests use backend-issued ids `n<epoch>-<n>`; a commit
  with the wrong id is refused, so a duplicate cannot repeat a move.
- **sessionId** — the compositor instance signature; `hello` must carry
  the current one.

## Handshake

```
→ hello  protocol=1  client=shell|observer  sessionId=…
← welcome protocol=1 backendEpoch=… sessionId=… grabbarVersion=… apiHash=… role=shell|observer
   (shell only:)
← window kind=snapshot …            one per tracked window
← snapshotEnd count=N
← state …
→ ready  restoreAccess=1|0          shell only; strips become active
← state …
```

Only one client may be the shell; a second gets `error reason=busy`. The
shell declares `restoreAccess=1` once a bar widget is mounted; without it the
strip is drawn but Minimize is refused. When the shell disconnects the
backend refuses new minimizes at once and starts the grace timer
(`plugin:grabbar:shell_grace_ms`, default 2000). If no shell returns in
time, every owned window is returned to a visible workspace and the strips
are suspended (reserved height 0).

## Messages the backend accepts

| Type | Fields | Who | Effect |
| --- | --- | --- | --- |
| `hello` | `protocol`, `client`, `sessionId` | any | Handshake |
| `ready` | `restoreAccess` | shell | Enables strips; `restoreAccess=1` enables Minimize |
| `ping` | — | any | `pong epoch=…` |
| `status` | — | any | `status json=…` (same JSON as `hyprctl grabbar -j`) |
| `snapshot` | — | any | Replays `window kind=snapshot` for every tracked window, then `snapshotEnd` |
| `action` | `action`, `windowToken`, `requestId`, + per action | any / shell | See below |
| `theme` | `barColor`, `inactiveBarColor`, `textColor`, `hoverColor`, `closeHoverColor` (`#rrggbb`/`#aarrggbb`/`reset`), `textFont` | shell | Overrides the `plugin:grabbar:*` colours/font |
| `settings` | `buttonsLeft=1|0|reset`, `controlSize=standard|large|reset`, `excludedClasses=a|b|c` | shell | Control placement/size and per-class exclusion |
| `pause` | `requestId` | shell | Disable: returns every owned window, then strips off and Minimize refused |
| `resume` | `requestId` | shell | Re-enable |

### Actions

| `action=` | Extra fields | Notes |
| --- | --- | --- |
| `minimizePrepare` | — | Asks the backend to start a minimize; it answers `result status=ok` and emits `minimizeRequest` to the shell |
| `minimizeCommit` | `requestId` from the `minimizeRequest` | Shell only, after its `prepared` journal record is on disk. Moves the window; `result` reports `ok`/`refused`/`failed` |
| `restore` | `destination=current|original`, `monitor=<name>`, `focus=1|0` | Returns an owned window (or an unrecorded one sitting on Grabbar's workspace) to the monitor's active workspace or its origin; falls back with an explanation in `error` |
| `restoreAll` | — | Returns every owned window to its origin (or current); `error` carries the count |
| `maximize` / `restoreSize` / `toggleMaximize` | — | Compositor maximized mode (never fullscreen) |
| `close` | — | Graceful close request; the window stays tracked until the compositor destroys it |
| `setFloating` | `value=1|0` | Move freely on/off |

Every action answers `result requestId=… action=… windowToken=… status=ok|stale|refused|failed error=…`
followed, on success, by the window's current fields.

## Messages the backend sends

| Type | When |
| --- | --- |
| `window kind=…` + window fields | `open`, `snapshot`, `title`, `fullscreen`, `floating`, `pin`, `workspace`, `maximize`, `closed`, `destroyedWhileMinimized`, `released` (another tool moved a hidden window; ownership dropped), `restored` (the window came back, by any path), and the action name after a successful action |
| `state` | `shellConnected`, `minimizeEnabled`, `suspended`, `paused`, `owned`, `tracked` |
| `minimizeRequest` | window fields + `requestId` + `source=bar|shell|client` — the shell must write its `prepared` record, then send `minimizeCommit` |
| `menuRequest` | window fields + `x`, `y` (global logical coordinates) — the shell opens the window menu |
| `notice` | `text` (plain, user-facing) + `token` |
| `event kind=backendStopping` | `reason`, `restored` — sent from `PLUGIN_EXIT` after owned windows were returned |
| `error` | `reason=protocol|session|busy|not-shell|unknown-message` |

### Window fields

`token owned alive address stableId pid class title workspace workspaceName
monitor monitorId floating pinned maximized fullscreen hidden modal x y w h`
and, while owned, `originWorkspace originWorkspaceName originMonitor
originFloating originPinned originMaximized request`. `class` is cut at 128
bytes, `title` at 256; the shell strips control characters again before
display and never persists titles.

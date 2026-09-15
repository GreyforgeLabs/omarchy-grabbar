# Security

Grabbar runs with the user's desktop privileges. Its design keeps every
operation narrow and tied to one live window:

- Actions carry backend-issued window tokens; stale or reused tokens answer
  `stale` and never fall back to the focused window.
- No shell commands are built from window titles, classes, workspace names
  or app IDs. Actions call typed compositor APIs with explicit window
  handles.
- The backend socket lives under `$XDG_RUNTIME_DIR/grabbar/<session>/`
  with `0700`/`0600` modes, bounded messages, protocol and session checks.
  Same-user clients are not a security boundary.
- The journal (`~/.local/state/grabbar/state.json`, `0600` in a `0700`
  directory) stores no titles, contents, command lines or environment.
  Symlinked or foreign-owned paths are refused; damaged files are
  quarantined, never followed.
- No network access, telemetry or automatic download. Building the native
  plugin is a user action.

## Reporting

Please report vulnerabilities privately by opening a GitHub security
advisory on this repository rather than a public issue. Include the Grabbar
version, the Hyprland build and steps to reproduce.

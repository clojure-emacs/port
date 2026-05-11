# Changelog

## 0.2.0-snapshot (unreleased)

## 0.1.0 (2026-05-11)

Initial release.

- TCP prepl client with a small EDN-ish reader (handles maps,
  vectors, and lists with simple leaf values).
- Two-socket session model: a user socket drives the REPL with raw
  streaming output, and a separate tool socket carries helper-command
  requests with reliable request/response correlation via a small
  `port.tooling/-eval` bootstrap.
- `M-x port` jacks in: detects `deps.edn` / `project.clj` / `bb.edn`,
  picks a free port, spawns a JVM running a prepl server, polls until
  reachable, and connects.  If a session is already active it just
  pops to the REPL, SLIME-style.
- Single-buffer REPL that renders `:ret`, `:out`, `:err`, and `:tap`
  messages.  Eldoc, completion-at-point, and persistent input history
  are wired into the prompt; killing the REPL buffer disconnects the
  session.
- Persistent REPL input history.  Each REPL buffer reads/writes
  `<project-root>/.port-history` (configurable via
  `port-repl-history-file`); `M-p` / `M-n` walk the history across
  sessions.  Capacity is `port-repl-history-size` (default 1000)
  and adjacent duplicates are dropped.
- Interactive eval commands: last-sexp, defun-at-point, region, buffer.
  Values returned through the tool-socket path are pretty-printed
  via `clojure.pprint`, capped by `port-print-length` (default 50)
  and `port-print-level` (default 5).  Multi-line results are
  truncated to the first line in the minibuffer; the full text
  appears in the REPL when `port-eval-display' is `both'.
- Helper commands powered by Clojure evaluation: doc, source, apropos,
  macroexpand-1, macroexpand, load-file, set-ns.
- Eldoc support: arglists for the function whose call surrounds point,
  resolved on the tool socket and delivered asynchronously via
  `eldoc-documentation-functions`.
- `completion-at-point` for symbols visible in the buffer's namespace,
  driven by a synchronous tool-socket request that walks `ns-map'.
- `port-find-definition` (bound to `M-.`) jumps to the source of the
  symbol at point using `:file` / `:line` from var metadata.  When
  the source lives inside a jar, the file's contents are slurped
  over the tool socket and shown in a read-only `*port-jar: ...*`
  buffer.
- Structured stacktrace buffer (`*port-stacktrace*`): on `:exception
  true` (and on `:tag :err` from the tool socket) Port renders a
  concise one-line summary inline and pops a navigable buffer with
  the cause chain, ex-data, and a filtered trace.  `RET` on a frame
  jumps to the source when the file resolves locally.
- `port-mode` minor mode for Clojure source buffers.  No hard
  dependency on `clojure-mode`; hook it onto whichever Clojure mode
  you use (`clojure-mode`, `clojure-ts-mode`, or both).

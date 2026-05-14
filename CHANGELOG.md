# Changelog

## 0.2.0-snapshot (unreleased)

- `completion-at-point` no longer blocks Emacs on every keystroke.
  Port now fetches the full symbol list for the buffer's namespace
  once and filters Elisp-side on subsequent capf calls; corfu /
  company-mode auto-popup feels instant after the first hit.  The
  cache is warmed asynchronously when `port-mode' is enabled with a
  session live, expires after `port-completion-cache-ttl` seconds
  (default 10), and gets cleared eagerly when `port-load-file' or
  `port-set-ns' runs.  `M-x port-completion-clear-cache' forces a
  refresh.  Set `port-completion-use-cache` to nil for the previous
  one-query-per-keystroke behaviour.
- Trace-frame jumps in `*port-stacktrace*` now reach jar-only
  frames.  `RET` on a frame whose `:file` doesn't resolve under
  `default-directory` or a project source root now asks the JVM
  via `clojure.java.io/resource` over the tool socket; jar URLs
  open the slurped source in the same `*port-jar: ...*` buffer
  cache `M-.` uses, `file:` URLs visit the path directly.  Two
  new defcustoms: `port-stacktrace-frame-form` (the lookup
  template) and `port-stacktrace-frame-timeout`.
- **Breaking:** `port-find-definition` is gone; replaced by a real
  `xref-backend-functions` entry installed by `port-mode`.  The
  default `M-.` / `M-,` bindings now route through Port whenever
  a session is live, and `xref-find-apropos` (`C-M-.` by default)
  returns matching symbols across all loaded namespaces, each
  resolved to its file:line.  Two new defcustoms:
  `port-xref-apropos-form` (the apropos query template, mirroring
  `port-xref-form`) and `port-xref-apropos-timeout` (default 5
  seconds, since walking `all-ns` isn't free).  References aren't
  implemented; for that, layer clojure-lsp via eglot or lsp-mode.
- `clojure.test` runner with a structured report buffer.  Four
  commands under `C-c C-t`: `t` runs the deftest at point, `n` the
  current namespace, `p` every loaded test-bearing namespace, and
  `r` re-runs whatever failed or errored last.  Results land in
  `*port-test-report*` with per-failure sections showing
  expected/actual and a `file:line` link to the source; `RET` on a
  link jumps, `n`/`p` walk failures, `g` re-runs the same
  selection.  Errors carry the captured `Throwable->map`, so `RET`
  on `(RET to show stacktrace)` pops the existing structured
  stacktrace buffer.  The Clojure-side machinery is held in
  `port-test-bootstrap-form`; the four entry-point templates are
  individual defcustoms (`port-test-run-ns-form` etc.) for dialect
  or library overrides.
- Optional [Orchard](https://github.com/clojure-emacs/orchard) and
  [Compliment](https://github.com/alexander-yakushev/compliment)
  integration via `port-orchard.el`.  `M-x port-enable-orchard' probes
  the running prepl for `orchard.info' and `compliment.core' and swaps
  in richer form templates for doc, eldoc, apropos, find-definition,
  and completion — independently per library.  Or `setq' the
  `port-orchard-*' / `port-compliment-*' defconsts persistently in
  your init.
- `port-enable-orchard-on-connect` defcustom: when non-nil,
  `port-enable-orchard' runs automatically after every successful
  jack-in / `port-connect'.  Paired with `port-jack-in-extra-deps' it
  gets Orchard from "opt-in" to "always on" in two settings lines.
- `port-after-connect-hook`: a hook run at the end of `port-connect'
  once the tool-socket bootstrap has been installed.  Used internally
  by `port-orchard.el' for the auto-enable wiring; available for any
  user-side extension that needs to fire helper-command requests
  immediately after connect.
- Dedicated `*port-taps*` history buffer for values published via
  `tap>`.  Each tap is appended with a timestamp header and rendered
  in `clojure-mode` (or `clojure-ts-mode`) for syntax highlighting.
  `port-show-taps` / `port-clear-taps` are bound to `C-c C-t v` /
  `C-c C-t c` in `port-mode`; the buffer is capped at
  `port-tap-max-entries` (default 100).
- `port-jack-in-extra-deps` defcustom: alist of `(DEP . VERSION)`
  pairs that get spliced into the JVM start command at jack-in
  (`clojure -Sdeps {...}` for tools-deps, chained
  `lein update-in :dependencies conj` for Leiningen).  Combined with
  the new `port-jack-in-orchard-deps' preset, opting into Orchard +
  Compliment is now a one-liner:

      (setq port-jack-in-extra-deps port-jack-in-orchard-deps)

- `port-jack-in` is now an alias for `port' — discoverable under the
  CIDER-style name for users with `cider-jack-in' muscle memory.
- Jack-in now configures `io-prepl` with a `clojure.pprint`-based
  `:valf` by default, so `:ret` and `:tap` values on the user socket
  arrive pretty-printed (bounded by `port-print-length` /
  `port-print-level`).  Set `port-jack-in-pretty-print` to nil for
  the old single-line `pr-str` behaviour.
- Every Clojure form Port sends to the prepl is now held in a
  `defcustom` — `port-doc-form`, `port-source-form`,
  `port-apropos-form`, `port-macroexpand-1-form`,
  `port-macroexpand-all-form`, `port-load-file-form`,
  `port-set-ns-form`, `port-eldoc-form`, `port-completion-form`,
  and `port-xref-form`.  Each defaults to a JVM `clojure.repl/*`-style
  form; override to target a different dialect (ClojureScript's
  `cljs.repl/*`, a Compliment-based completion variant, etc.) without
  having to fork Port.

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

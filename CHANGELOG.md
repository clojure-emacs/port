# Changelog

## main (unreleased)

### New features

- Wire-level message log for debugging: `M-x port-toggle-message-log` (or `port-log-messages t`) mirrors every outgoing form and incoming parsed message to `*port-messages*`, timestamped to the millisecond and labelled `user` / `tool`.  Off by default.
- Eldoc highlights the active argument and shows a short docstring preview alongside the arglist.  Multi-arity arglists are parsed and the arity matching the current position picked automatically.  Customisable via `port-eldoc-arg-index-function` and `port-eldoc-arglist-formatter`.

### Bugs fixed

- Fix Emacs hang when a large prepl response (e.g. the completion warm-up against a namespace with thousands of vars) arrived in many TCP chunks.  The process filter used to re-parse the accumulated buffer from byte 0 on every chunk; it now defers parsing until a real newline arrives, at most one parse per inbound message.  ~10x speedup on 100KB responses.

### Changes

- REPL input-completeness check rewritten on top of `parse-partial-sexp` + the new `port-repl-input-syntax-table` defvar.  Same observable behaviour, override-friendly for dialect variants.

## 0.2.0 (2026-05-14)

### New features

- `clojure.test` runner with a navigable `*port-test-report*` buffer.  `C-c C-t t` runs the deftest at point, `C-c C-t n` the current namespace, `C-c C-t p` every loaded test-bearing namespace, `C-c C-t r` re-runs the failures.  `RET` on a failure jumps to source or pops the stacktrace; `n`/`p` walk failures, `g` re-runs the same selection.
- Optional [Orchard](https://github.com/clojure-emacs/orchard) and [Compliment](https://github.com/alexander-yakushev/compliment) integration via `port-orchard.el`.  `M-x port-enable-orchard` probes the running prepl and swaps in richer form templates for doc, eldoc, apropos, find-definition, and completion.
- `port-enable-orchard-on-connect`: when non-nil, runs `port-enable-orchard` automatically after every successful jack-in / `port-connect`.
- `port-after-connect-hook`: a hook run at the end of `port-connect` once the tool-socket bootstrap has been installed.
- Dedicated `*port-taps*` history buffer for values published via `tap>`, bound to `C-c C-t v` (view) and `C-c C-t c` (clear).  Capped at `port-tap-max-entries` (default 100).
- `port-jack-in-extra-deps` splices extra Maven coords into the jack-in command (tools-deps via `-Sdeps`, Leiningen via chained `update-in :dependencies conj`).  Ships with a `port-jack-in-orchard-deps` preset for one-line Orchard + Compliment opt-in.
- `M-x port` jacks in to babashka projects (`bb.edn`).  Override the binary via `port-jack-in-babashka-program`.
- Optional inline eval-result overlays via `port-eval-overlay` (off by default).  Composes with `port-eval-display`; errors get a distinct face.

### Changes

- **Breaking:** `port-find-definition` is gone; Port now installs an `xref-backend-functions` entry, so `M-.` / `M-,` route through the standard xref UI.  `xref-find-apropos` is also wired up.
- `xref-find-definitions` offers tab-completion at the prompt from the per-namespace symbol cache.
- `completion-at-point` no longer blocks Emacs on every keystroke.  Port pre-fetches the buffer's symbol list once per namespace and filters Elisp-side; the cache is warmed asynchronously and cleared by `port-load-file` / `port-set-ns`.  Opt out via `port-completion-use-cache` nil.
- Trace-frame jumps in `*port-stacktrace*` now reach jar-only frames.  When local resolution misses, Port asks the JVM via `clojure.java.io/resource` and renders jar URLs in the shared `*port-jar: ...*` buffer cache.
- Jack-in now configures `io-prepl` with a `clojure.pprint`-based `:valf` by default, so `:ret` and `:tap` values arrive pretty-printed.  Opt out via `port-jack-in-pretty-print` nil.
- `port-jack-in` is now an alias for `port`, matching `cider-jack-in` muscle memory.
- Every Clojure form Port sends to the prepl is now held in a `defcustom` (`port-doc-form`, `port-source-form`, `port-apropos-form`, etc.), making it easy to swap in dialect- or library-specific variants without forking Port.

## 0.1.0 (2026-05-11)

Initial release.

### New features

- TCP prepl client with a small EDN-ish reader for the subset of values prepl emits.
- Two-socket session model: a user socket drives the REPL with raw streaming output; a separate tool socket carries helper-command requests, correlated via a small `port.tooling/-eval` bootstrap.
- `M-x port` jacks in: detects `deps.edn` / `project.clj` / `bb.edn`, picks a free port, spawns the JVM, polls until reachable, and connects.
- Single-buffer REPL rendering `:ret`, `:out`, `:err`, and `:tap` messages.  Eldoc, completion-at-point, and persistent input history wired into the prompt; killing the buffer disconnects the session.
- Persistent REPL input history (`.port-history` under the project root by default), capped at `port-repl-history-size` and walkable via `M-p` / `M-n`.
- Interactive eval commands (last-sexp, defun-at-point, region, buffer), pretty-printed via `clojure.pprint` and capped by `port-print-length` / `port-print-level`.
- Helper commands: doc, source, apropos, macroexpand-1, macroexpand, load-file, set-ns.
- Async eldoc: arglists for the function whose call surrounds point.
- `completion-at-point` for symbols visible in the buffer's namespace.
- `port-find-definition` (bound to `M-.`) jumps to the source of the symbol at point, slurping jar contents into a read-only `*port-jar: ...*` buffer when needed.
- Structured stacktrace buffer (`*port-stacktrace*`) on `:exception true` or `:tag :err`, with the cause chain, ex-data, and a filtered trace with file:line jumps.
- `port-mode` minor mode for Clojure source buffers; no hard dependency on `clojure-mode`.

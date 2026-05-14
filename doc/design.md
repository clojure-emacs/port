# Port Design Document

This document explains how Port is built and the rationale behind the
design decisions.  It targets contributors and curious users; if you
just want to use Port, the [README](../README.md) is enough.

## Goals

- Provide a Clojure interactive programming environment for Emacs in
  the style of CIDER and [monroe](https://github.com/sanel/monroe).
- Build on top of Clojure's built-in **prepl**
  (`clojure.core.server/io-prepl`) instead of nREPL, so that no
  server-side dependencies, plugins, or middleware are needed beyond
  Clojure itself.
- Stay small.  The whole codebase should fit in a single afternoon's
  reading.
- Keep the user-facing REPL buffer authoritative: every interaction
  should be representable as something the user could have typed at
  the REPL prompt, so there is no hidden state.

## Non-goals (for now)

- Feature parity with CIDER.  Things like the inspector, debugger,
  test runner, profiler, and structured stacktrace browser are
  deliberately deferred.
- ClojureScript-specific tooling.  Plain Clojure prepl is the focus;
  ClojureScript via shadow-cljs/figwheel etc. is out of scope.
- Persistent session state across restarts (history is persisted,
  but anything else — namespaces, defs, server state — is not).

## Background: prepl

prepl is a streaming text protocol that ships with Clojure.  The
server reads top-level forms from a TCP socket, evaluates them, and
writes a sequence of EDN-tagged maps describing the outcome:

```
{:tag :ret, :val "3", :ns "user", :ms 1, :form "(+ 1 2)"}
{:tag :out, :val "hello\n"}
{:tag :err, :val "..."}
{:tag :tap, :val "..."}
{:tag :ret, :val "{:via [...]}", :ns "user", :ms 0,
            :form "(/ 1 0)", :exception true}
```

Compared to nREPL, prepl is intentionally minimal:

- No bencode; everything is plain text/EDN.
- No "ops"; you just send Clojure forms.
- No sessions, no middleware, no extension surface.
- No request id.  Tags identify the **kind** of message, not which
  request produced it.

That last point is the central design constraint.  If you want a tool
on top of prepl that issues a request and reliably reads back its
result without picking up output from unrelated forms, you need to
layer correlation on top of the protocol.  Port does this with two
sockets and a small bootstrap form (see
[The correlation problem](#the-correlation-problem) below).

To start a prepl server:

```
clj -X clojure.core.server/start-server \
    :name '"port"' :port 5555 \
    :accept clojure.core.server/io-prepl
```

The server accepts as many concurrent TCP connections as you want.

## Architecture overview

A Port **session** holds two independent prepl connections to the
same server:

```
                            +-----------------------+
                            |    prepl server       |
                            | (clj or embedded)     |
                            +-----------+-----------+
                                        |
                  TCP                   |                TCP
       +--------------------+           |       +-------------------+
       |   user socket      |<----------+------>|   tool socket     |
       |   port-client      |                   |   port-client     |
       +---------+----------+                   +---------+---------+
                 |                                        |
                 |  raw streaming messages                |  correlated
                 |  (:ret/:out/:err/:tap)                 |  result maps
                 |                                        |
                 v                                        v
       +--------------------+                   +-------------------+
       |  REPL buffer       |                   |  callback alist   |
       |  (port-repl)       |                   |  (port-session    |
       +--------------------+                   |   pending)        |
                                                +-------------------+
```

The user socket drives the REPL buffer with raw streaming output.
The tool socket runs a one-shot bootstrap form on connect that
defines `port.tooling/-eval`, then carries every helper-command
request wrapped in that function.  The wrapper attaches a request id
to each result, which lets the client match responses to pending
callbacks.

This separation has three consequences:

1. The user's REPL stays clean — direct evals from a Clojure source
   buffer behave exactly like typing at the prompt.
2. Helper commands (doc, completion, eldoc, find-definition) get a
   stable channel where each request has exactly one resulting
   `:ret` whose `:val` they can claim by id.
3. Background output from `future`/`agent`/`tap>` on the user thread
   doesn't pollute tool requests.  (Background output on the **tool**
   socket can still leak in, but it's rare in practice and harmless —
   the dispatcher ignores anything without a matching id.)

## The correlation problem

prepl's stream looks like this in the worst case:

```
user> (future (Thread/sleep 100) (println "hi"))
{:tag :ret  :val "#<Future ...>"  :ns "user"  :form "..."}
user> (clojure.repl/doc map)
{:tag :out  :val "hi\n"}                  ;; <-- from the previous future!
{:tag :out  :val "-------------------------\n"}
{:tag :out  :val "clojure.core/map\n"}
...
{:tag :ret  :val "nil"  :ns "user"  :form "(clojure.repl/doc map)"}
```

A naive client cannot tell whether the first `:out` belongs to its
`doc` request or to the lingering future from a previous form.  Three
realistic ways to fix this:

1. **Form-echo marker.**  Every `:ret` carries `:form`, which we can
   embed a unique marker into (e.g. wrap as `(do <user-form> ::id-N)`).
   Cheap but doesn't survive exceptions.
2. **Wrap each tool call in a try/catch that returns a tagged map.**
   Always emits exactly one `:ret`; `*out*` and `*err*` can be bound
   inside the wrapper so they don't pollute the connection.
3. **Use a separate prepl connection for tooling.**  Background
   output from user code lives on the user socket; tool requests have
   the tool socket largely to themselves.

Port combines (2) and (3): a dedicated tool socket where every
helper request goes through `port.tooling/-eval`, which captures
output and returns a tagged result map.  The `:port/id` field in the
returned map is what the client matches against its pending-callback
registry.

This is essentially what nREPL achieves via sessions, just at a
different layer: sessions in nREPL are an application-layer concept
on top of bencode; in Port they're an application-layer concept on
top of TCP.

## Components

```
lisp/
├── port.el              entry point, port-connect / port-disconnect
├── port-client.el       single TCP connection + EDN-ish reader
├── port-session.el      pair of connections + callback registry
├── port-tooling.el      bootstrap form, port-tooling-call dispatcher
├── port-repl.el         REPL buffer mode
├── port-eval.el         interactive eval commands (source -> user socket)
├── port-mode.el         minor mode + helper commands
├── port-eldoc.el        async arglist lookup (eldoc-documentation-functions)
├── port-completion.el   sync ns-map walk for completion-at-point
├── port-stacktrace.el   parsed Throwable->map renderer + frame navigation
├── port-tap.el          *port-taps* history buffer for tap> values
├── port-test.el         clojure.test runner + *port-test-report* buffer
└── port-xref.el         var meta -> file:line for find-definition (M-.)
```

### `port-client.el`

The protocol primitive.  Owns a single TCP connection and the parsing
of streamed prepl messages.

The `port-client` struct stores the socket process, a private buffer
for parser leftover bytes, the current namespace tracked from `:ret`
messages, and a per-connection message handler.  Different connections
plug different handlers: the user socket gets one that renders into a
REPL buffer; the tool socket gets one that dispatches to pending
callbacks.

The handler indirection is what lets the same primitive serve both
sockets without `port-client` needing to know anything about REPL
buffers or callbacks.

### `port-session.el`

A `port-session` ties two `port-client`s and a REPL buffer together,
plus a monotonically increasing request-id counter and a pending-call
alist (`((id . callback) ...)`).  `port-default-session` holds the
most recent session globally; for the MVP there is only ever one
active session.

Multi-session support (à la sesman) is feasible later: each
clojure-mode buffer can hold a buffer-local `port--session` reference
and `port-current-session` would resolve to that first, falling back
to the default.  None of the existing code prevents that — the
single-session global is just the simplest thing that works today.

### `port-tooling.el`

Defines the bootstrap form sent on connect, plus `port-tooling-call`
(async) and `port-tooling-call-sync` (blocking via
`accept-process-output`).

The bootstrap is a single Clojure form:

```clojure
(do (clojure.core/ns port.tooling)
    (clojure.core/defn -eval [id thunk]
      (let [out-buf (java.io.StringWriter.)
            err-buf (java.io.StringWriter.)]
        (binding [*out* out-buf *err* err-buf]
          (try
            (let [v (thunk)]
              {:port/id id :tag :ok :val (pr-str v)
               :out (str out-buf) :err (str err-buf)})
            (catch Throwable t
              {:port/id id :tag :err :ex (pr-str (Throwable->map t))
               :out (str out-buf) :err (str err-buf)}))))))
```

A few things worth noting:

- `*out*` and `*err*` are rebound to `StringWriter`s for the duration
  of the call.  Any printing the user form does is captured into the
  result map rather than dribbling into the socket as `:out` messages.
  Background threads (`future`, `agent`) do **not** see this binding
  — Clojure's dynamic bindings are thread-local — so their output goes
  to the original `*out*` (i.e. the connection's writer) and surfaces
  as a stray `:out` message on the tool socket.  The dispatcher
  ignores those.
- `-eval`'s `:val` is `pr-str`'d.  This sidesteps the parser having
  to handle every EDN value type — strings, numbers, keywords, maps
  with those leaf types, plus the printed-string trick handle 95% of
  what the helper commands need.  `:ex` is `pr-str`'d too; the
  stacktrace renderer re-parses it through the same reader.
- A second wrapper, `-user-eval`, handles the source-buffer eval
  path.  It rebinds `*ns*` (so `(in-ns ...)` and unqualified
  references resolve correctly) and produces `:val` via
  `clojure.pprint/pprint` under caller-supplied `*print-length*` /
  `*print-level*` caps.  This is the only place we pretty-print; the
  internal `-eval` path keeps `pr-str` so its results stay
  re-parseable.
- The result map carries `:out` and `:err` even on success, so a
  helper that returns a value but also prints something can render
  both.

`port-tooling-call` allocates an id, registers a callback, and sends
`(port.tooling/-eval <id> (fn [] <user-form>))`.  When the matching
`:ret` arrives, the tool-socket handler parses its `:val` as an EDN
map, extracts `:port/id`, pops the callback from the session's
pending alist, and fires it.

`port-tooling-call-sync` is a thin wrapper that spins on
`accept-process-output` until the callback runs or a timeout
elapses.  It exists for `completion-at-point-functions`, which has
no native async hook.

### `port-repl.el`

A custom major mode (not comint).  The buffer is split conceptually
into two regions: read-only output above `port-repl-input-start-marker`
and an editable input area at the end.  Each prepl message produces
one chunk of output, faced according to its tag (`:ret`/`:out`/`:err`/
`:tap` get distinct faces).

`RET` on the input line submits when the input is balanced (a small
character-by-character paren counter that respects strings and `;`
comments) and inserts a literal newline otherwise — so multiline
forms are easy to type without an explicit "send" key.

When output arrives while the user is mid-typing, the renderer
saves the in-progress input, deletes the prompt and input region,
emits the output above where the prompt was, redraws the prompt, and
re-inserts the saved input.  This is uglier than it sounds but
preserves the typing UX.

Input history is persisted between sessions.  By default we write
to `<project-root>/.port-history` (one `prin1`'d entry per line);
`port-repl-history-file` overrides the path or disables persistence
with `t`.  The file is loaded once at REPL-buffer creation, trimmed
to `port-repl-history-size` entries, and appended to on each send.
Adjacent duplicates are skipped so hammering on `RET` doesn't fill
the ring.

### `port-eval.el` and `port-mode.el`

`port-eval-string` is the only path code from a source buffer takes
to the user socket.  It writes the form into the REPL buffer as if
the user had typed it, then sends it.  All four interactive eval
commands (`port-eval-last-sexp`, `port-eval-defun-at-point`,
`port-eval-region`, `port-eval-buffer`) come down to this.

`port-mode` is the buffer-local minor mode that installs the
keybindings and wires `port-eldoc-setup` /
`port-completion-setup` / their teardown counterparts.

The helper commands defined in `port-mode.el` split along a
deliberate axis:

- **Side-effecting commands** (`port-load-file`, `port-set-ns`) go
  through the user socket.  Loading a file or switching namespace
  changes the user's REPL state, and the user should see that
  reflected at the REPL prompt.
- **Read-only commands** (`port-doc`, `port-source`, `port-apropos`,
  `port-macroexpand-1`, `port-macroexpand`) go through the tool
  socket via `port-tooling-call`.  Their callbacks render the
  captured `:out` into the REPL buffer so the user still sees output
  in one place.

### `port-eldoc.el`

The eldoc backend uses `eldoc-documentation-functions`'s async
callback form: when invoked, it dispatches a tool-socket request and
returns non-nil to tell eldoc "I'll deliver later".  When the response
arrives, the callback decodes the printed-string value (via
`port-tooling-decode-val`) and hands the formatted arglist string to
eldoc.

Target detection finds the function being called by walking up to
the head of the enclosing list (via `syntax-ppss`).  Eldoc's
existing idle timer governs how often we send requests, so we don't
need our own debounce.

### `port-completion.el`

Completion-at-point is synchronous in Emacs — the API expects a list
of candidates returned right now.  We use `port-tooling-call-sync`
with a 2-second timeout.

The Clojure side walks `ns-map` of the buffer's namespace, filters
by prefix, dedups, sorts, and joins with newlines.  The Elisp side
splits on newline.  This is not the most efficient encoding (a vector
would be more natural) but it sidesteps the EDN reader's lack of
list/vector support without forcing a parser extension before it's
needed elsewhere.

### `port-xref.el`

An `xref-backend-functions' implementation rather than a bespoke
command.  `port-mode' installs `port-xref-backend' as a buffer-local
hook; whenever a session is live it returns the symbol `port`, and
the various `xref-backend-*' generic functions dispatch on
`(eql port)' to Port's implementations.  The upshot is that
`M-.`, `M-,`, and `xref-find-apropos' work on Clojure symbols
without Port needing any custom keybindings.

Two operations are wired up.  `xref-backend-definitions' issues
`port-xref-form' synchronously on the tool socket (via
`port-tooling-call-sync', because xref's API is sync), parses the
returned map, and resolves to one of three location types:

1. Absolute `:file` that exists locally → `xref-file-location'.
2. `:file` resolvable under `default-directory' → ditto.
3. Jar URL with embedded `:contents' → a `*port-jar: foo.jar!/...*'
   read-only buffer is materialised up front so the returned
   `xref-buffer-location' lands users straight in `clojure/core.clj`
   for vars like `clojure.core/map`.

`xref-backend-apropos' issues a second form (`port-xref-apropos-form')
that walks `all-ns' once on the server side and returns a vector of
`{:name :file :line :doc}' maps for symbols matching the pattern;
each row turns into an `xref-item` with a `doc`-augmented summary
when one is present.  Jar-internal entries are filtered server-side
because slurping every jar for an apropos list would dominate the
roundtrip.  The bigger `port-xref-apropos-timeout' (default 5s)
reflects the bigger query.

References aren't implemented.  Finding actual call sites needs
static analysis; clojure-lsp via eglot/lsp-mode is the supported
path for users who want that.

### `port-stacktrace.el`

The renderer for parsed `Throwable->map` data.  Both error paths
funnel here:

- The user socket: when a `:ret` arrives with `:exception true`, the
  REPL handler parses the printed `Throwable->map` from `:val` and
  hands it to `port-stacktrace-display`.  The REPL itself only emits
  a one-line `Type: message` summary so the prompt stays clean.
- The tool socket: when a wrapped call returns `:tag :err`, the
  result map carries `:ex` (the printed `Throwable->map`) and
  `:ex-message`.  Both `port-mode`'s helper-command emitter and
  `port-eval--display-result` call `port-stacktrace-pop-from-result`,
  which parses `:ex` and pops the buffer if it parses cleanly.

The buffer shows the `:via` chain at the top — each entry rendered
as `<Type>: <message>` plus expanded `:data` if any — followed by
the `:trace` frames.  Internal frames (`clojure.lang.*`,
`clojure.core$*`, `java.*`, `sun.*`, `nrepl.*`) are filtered by
default; the user can flip `port-stacktrace-hide-clojure-internals`
to see everything.  `RET` on a frame attempts to visit its source,
trying `default-directory` and a few common project source roots.

### `port-test.el`

The `clojure.test` runner.  A single bootstrap form
(`port-test-bootstrap-form`) defines a `port.test` namespace on the
tool socket with four entry points: `-run-ns`, `-run-var`, `-run-all`,
`-rerun-failed`.  Each wraps the actual `clojure.test` call in
`with-redefs` on `clojure.test/report` to capture per-assertion events
into an atom while still chaining to the original report (so
`inc-report-counter!` and friends still fire and `:summary` carries
accurate counts).  The result map shape is
`{:summary {:test N :pass N :fail N :error N} :results [...]}`, where
each entry in `:results` is a printed map carrying `:type`, `:ns`,
`:var`, `:file`, `:line`, `:expected`, `:actual`, plus `:ex` and
`:ex-message` on errors so a stacktrace can be popped on demand.

The bootstrap is sent lazily — the first test command installs it,
subsequent commands send only the entry-point call.  Sessions that
already received it are tracked in `port-test--installed-sessions`.

Rendering lives in `port-test--render`, which writes into a
`special-mode`-derived `port-test-report-mode` buffer with text
properties on each failure section: `port-test-jump-target` carries
the `(file . line)` pair, `port-test-stacktrace` carries the printed
`Throwable->map`, and `port-test-failure` marks the whole entry for
`n` / `p` navigation.  Source resolution reuses
`port-stacktrace--locate-relative` so classpath-relative file paths
resolve against `default-directory` and common project source roots,
same as the stacktrace buffer.

The four entry-point templates are individual defcustoms
(`port-test-run-ns-form` etc.), so swapping in a different test
runner (kaocha, eftest) or a ClojureScript-flavored equivalent is a
matter of setting the corresponding format string.

### `port-tap.el`

A dedicated `*port-taps*` history buffer that accumulates values
published via `tap>`.  `io-prepl` already wires `tap>` to emit
`:tag :tap` messages on the user socket; `port-repl.el` keeps the
one-line `;; tap> <val>` preview in the REPL but also calls
`port-tap-append` so the full value lands in a clojure-mode buffer
where the user can browse, copy, and navigate it.

Entries are separated by a `;; tap @ HH:MM:SS` header; the buffer is
capped at `port-tap-max-entries` (oldest entry dropped on overflow).
`port-show-taps` and `port-clear-taps` are bound to `C-c C-t v` and
`C-c C-t c` in `port-mode`.

In jack-in mode `port-jack-in-pretty-print` (default `t`) configures
`io-prepl` with a `clojure.pprint`-based `:valf`, so tapped values
(and interactive eval results) arrive multi-line and indented on the
wire.  In `port-connect` mode the user controls how the prepl was
started, so we fall back to `clojure-mode`-driven `indent-region` on
the inserted value as a best-effort.

## Wire format and the EDN-ish reader

prepl emits one EDN map per message, separated by newlines (`prn` adds
the newline).  The values we encounter in practice are limited:
strings, integers, keywords, maps, vectors, lists, booleans, nil.
The reader in `port-client.el` handles exactly that subset — no sets,
namespaced map shorthand, metadata, character literals, ratios, big
decimals, regexes, or tagged literals.

This is enough because:

- Outer prepl messages are flat maps with string/keyword/integer/bool
  leaves.
- Inner result maps from the bootstrap match the same shape because
  `:val` and `:ex` are `pr-str`'d into strings.  The stacktrace
  module re-parses those strings into nested vectors+maps using the
  same reader.
- Helper-command return values are either strings (most cases) or
  small maps with simple leaves (`port-xref`).

The reader signals a custom `port-edn-incomplete` condition for
truncated input, which the filter catches to buffer leftover bytes
until the next chunk arrives.

## Synchronous vs asynchronous patterns

Three patterns coexist:

1. **Pure async, REPL-rendered.**  Direct evals and the user-socket
   helpers (`port-load-file`, `port-set-ns`).  The user sends, output
   streams into the REPL.  No callbacks.
2. **Async with callback.**  Tool-socket helpers (`port-doc`,
   `port-source`, eldoc, the test runner).  `port-tooling-call`
   delivers the result map to a callback once the matching `:ret`
   arrives.
3. **Sync.**  Completion-at-point and the xref backend.
   `port-tooling-call-sync` blocks on `accept-process-output` until
   the callback fires or the timeout elapses.  Used sparingly,
   because xref's API and `completion-at-point-functions' both
   demand synchronous returns.

Pattern (3) is the only place we block Emacs.  We use it sparingly
because completion is user-initiated and cap the wait at
`port-completion-timeout` (2 seconds by default).

## Trade-offs vs CIDER and monroe

**vs CIDER.**  CIDER is built on nREPL with a substantial middleware
ecosystem (`cider-nrepl`, `refactor-nrepl`).  That gives it
features Port doesn't have: structured stacktrace viewer, debugger,
inspector, test runner, profiler, log viewer, semantic
completion, smart resolution of jar source files, etc.  Port's bet
is that the prepl model is enough for a meaningful subset of CIDER
and that the smaller surface area is worth the missing features for
people who want something simpler.

**vs monroe.**  monroe is in the same spirit as Port — small,
single-buffer REPL, helper commands implemented by sending Clojure
forms — but uses nREPL (not prepl) and runs everything on one
connection without an explicit correlation layer.  Port's two-socket
model gives us reliable correlation, which monroe doesn't try to
solve, and we're paying for that with a slightly more complex
architecture.

## Known limitations

- Jack-in covers `deps.edn` and `project.clj` only.  Babashka,
  shadow-cljs, and per-project alias selection (`-A:dev` etc.) are not
  yet supported; users with those setups can still launch the prepl
  manually and `M-x port-connect`.
- Trace-frame source resolution is best-effort.  Frames whose
  `:file` is a classpath-relative basename only resolve when the
  file is found under `default-directory` or a common project
  source root; we don't currently round-trip back to the JVM to
  ask `clojure.java.io/resource` per frame the way the M-. path
  does.
- Completion is synchronous; under network latency or auto-popup
  setups (corfu, company auto-complete) it can feel sluggish.
- Single-session only.  Connecting again replaces the previous
  session.
- `port-repl-interrupt` is a stub.  prepl has no interrupt op;
  implementing it requires either out-of-band signaling or a
  process-level kill.

## Future directions

In rough priority order:

1. Trace-frame source resolution via the tool socket (round-trip
   to `clojure.java.io/resource` per frame), so jar-only frames
   become navigable too.
2. Jack-in for shadow-cljs, plus per-project alias selection.
3. Multi-session support keyed per clojure-mode buffer.
4. CIDER-style result overlays (deliberately listed last; the
   "all output goes to the REPL" UX is a deliberate choice).

## Versioning

Port is pre-release.  Until a real `0.1.0` tag is cut, everything
lives under `0.1.0-snapshot` and breaking changes can land without
notice.

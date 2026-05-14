# Port

A minimalist Clojure interactive programming environment for Emacs, in the
spirit of [CIDER](https://github.com/clojure-emacs/cider) and
[monroe](https://github.com/sanel/monroe), built on top of Clojure's built-in
[prepl](https://clojure.org/reference/repl_and_main#prepl) instead of nREPL.

> Status: prototype / MVP. Expect rough edges.

## Features

- `M-x port` jacks in (auto-detects `deps.edn` / `project.clj` /
  `bb.edn`), or `M-x port-connect` attaches to a prepl you started
  yourself.
- Single-buffer REPL with persistent input history.
- Interactive evaluation from source buffers (`C-c C-e`, `C-c C-c`, ...),
  pretty-printed via `clojure.pprint` with configurable length/level caps.
- Structured stacktrace buffer for exceptions: cause chain, ex-data,
  navigable frames.
- Eldoc, completion-at-point, doc/source/apropos/macroexpand helpers,
  and an xref backend for `M-.` / `xref-find-apropos` that follows
  into jar sources.
- Dedicated `*port-taps*` buffer that accumulates values published via
  `tap>`, with `C-c C-t v` to view and `C-c C-t c` to clear.
- `clojure.test` runner with a structured `*port-test-report*` buffer:
  navigable per-failure entries, `RET` to jump to the source or pop
  a stacktrace, and `port-test-rerun-failed` to retry only what
  broke.

## Why prepl?

prepl (`clojure.core.server/io-prepl`) is a streaming text protocol that
ships with Clojure itself. No bencode, no middleware, no sessions: send a
Clojure form, read back a sequence of EDN messages tagged `:ret`, `:out`,
`:err`, or `:tap`. That makes Port small, portable, and easy to reason about,
at the cost of features that nREPL middleware would otherwise provide.

Where CIDER asks the server (via middleware) for things like documentation
or completion, Port leans on the same trick `inf-clojure` uses: just evaluate
a Clojure form (e.g. `(clojure.repl/doc foo)`) and read what the REPL prints
back. monroe is a bit different: it talks plain nREPL, so most of what it
needs (eval, interrupt, load-file, session management) is already a built-in
op; it only falls back to sending forms for things stock nREPL doesn't cover.

## Compared to other Clojure tools for Emacs

The Clojure-on-Emacs landscape is a ladder. Each rung adds structure to how
the editor talks to a running Clojure.

| Tool             | Protocol                              | Server-side deps              |
|------------------|---------------------------------------|-------------------------------|
| [inf-clojure][]  | comint over stdio (or a socket REPL)  | none                          |
| **Port**         | prepl (TCP)                           | none (built into Clojure)     |
| [monroe][]       | nREPL                                 | nREPL                         |
| [CIDER][]        | nREPL + cider-nrepl middleware        | nREPL + cider-nrepl           |

**inf-clojure** sits closest to the metal. It runs a Clojure (or babashka,
Planck, ...) subprocess under Emacs's [`comint`][comint] and parses its
plain-text output. Helper commands like documentation and arglist lookup go
through predefined code snippets and screen-scraping. Universal and cheap,
but the lack of structured output means the editor can't always tell apart a
return value, stdout, and an error.

**Port** is one rung up. prepl is a tiny TCP protocol that ships with Clojure
itself, emitting tagged EDN messages (`:ret`, `:out`, `:err`, `:tap`,
`:exception`) instead of plain text. That structure is enough to build
reliable tooling on top, once you add a small bootstrap form for request /
response correlation (see [`doc/design.md`](doc/design.md)). Helper commands
still come from sending Clojure forms, the same idea as inf-clojure, but Port
can tell which response goes with which request without scraping prose.

**monroe** uses [nREPL][], whose protocol provides sessions, ops, and request
ids out of the box. The editor side stays small because nREPL gives it those
primitives for free. No middleware required beyond plain nREPL.

**CIDER** is the maximalist rung: nREPL plus the [cider-nrepl][] middleware
suite, plus a substantial editor codebase. The middleware adds server-side
support for things that aren't cheap to build on bare nREPL: debugger,
inspector, test runner, profiler, structured stacktrace browser, refactoring.
Heavier setup, vastly more features.

The bulk of each project lives wherever its protocol has the gaps.
inf-clojure is small because `comint` already exists. monroe is small because
nREPL already gives it primitives. Port has to be slightly bigger than monroe
(the two-socket model, the bootstrap) because prepl gives it less. CIDER's
bulk isn't even Emacs Lisp; it's `cider-nrepl`, server-side, because that's
where nREPL is meant to be extended.

Pick the rung you want: maximum power → CIDER; small structured client over
prepl → Port; small client over nREPL → monroe; zero server-side requirements
→ inf-clojure.

[inf-clojure]: https://github.com/clojure-emacs/inf-clojure
[monroe]: https://github.com/sanel/monroe
[CIDER]: https://github.com/clojure-emacs/cider
[nREPL]: https://nrepl.org
[cider-nrepl]: https://github.com/clojure-emacs/cider-nrepl
[comint]: https://www.masteringemacs.org/article/comint-writing-command-interpreter

## Installation

Port isn't on MELPA yet; it should get there once we cut a real release.
In the meantime, the easiest way is `package-vc-install` on Emacs 29+:

```elisp
(package-vc-install
 '(port :url "https://github.com/clojure-emacs/port"
        :branch "main"
        :lisp-dir "lisp"))
```

On Emacs 30+ with [`use-package`](https://github.com/jwiegley/use-package)
you can put the same form in your config and let it handle install:

```elisp
(use-package port
  :vc (:url "https://github.com/clojure-emacs/port" :branch "main" :lisp-dir "lisp")
  :hook ((clojure-mode    . port-mode)
         (clojure-ts-mode . port-mode)))
```

`:lisp-dir "lisp"` is needed because Port's sources live under `lisp/` rather
than at the repository root; without it `package-vc-install` won't add that
directory to `load-path` and byte-compilation will fail.

Port doesn't depend on any specific Clojure mode. Hook it onto whichever
one(s) you actually use (`clojure-mode`, `clojure-ts-mode`, or both).

For a manual checkout (e.g. while contributing):

```elisp
(add-to-list 'load-path "/path/to/port/lisp")
(require 'port)
(add-hook 'clojure-mode-hook    #'port-mode)
(add-hook 'clojure-ts-mode-hook #'port-mode)
```

## Starting a prepl

Easiest path: let Port spawn one for you. Visit a file in your project and
run `M-x port` (or its alias `M-x port-jack-in`). It auto-detects the project
layout (`deps.edn`, `project.clj`, or `bb.edn`), picks a free port in
`5555-5574`, starts a JVM with a prepl server, and connects when the port
comes up. The server's stdout/stderr lands in a `*port-server*` buffer below
the REPL.

If you'd rather run the prepl yourself (handy for embedding it in a
long-running application or pre-warming the JVM), start it like this:

```
clojure -M -e '(do (clojure.core.server/start-server
                     {:name "port" :port 5555
                      :accept (quote clojure.core.server/io-prepl)})
                   @(promise))'
```

then attach from Emacs with `M-x port-connect` (defaults to `localhost:5555`).

## Key bindings (in `port-mode`)

| Binding   | Command                       |
|-----------|-------------------------------|
| `C-c C-e` | `port-eval-last-sexp`         |
| `C-c C-c` | `port-eval-defun-at-point`    |
| `C-c C-r` | `port-eval-region`            |
| `C-c C-k` | `port-eval-buffer`            |
| `C-c C-l` | `port-load-file`              |
| `C-c C-d` | `port-doc`                    |
| `C-c C-s` | `port-source`                 |
| `C-c C-m` | `port-macroexpand-1`          |
| `C-c M-n` | `port-set-ns`                 |
| `C-c C-z` | `port-switch-to-repl`         |
| `C-c C-t v` | `port-show-taps`            |
| `C-c C-t c` | `port-clear-taps`           |
| `C-c C-t t` | `port-test-run-at-point`    |
| `C-c C-t n` | `port-test-run-ns`          |
| `C-c C-t p` | `port-test-run-project`     |
| `C-c C-t r` | `port-test-rerun-failed`    |

`M-.`, `M-,`, and `xref-find-apropos` come from Emacs's built-in
`xref` and route through Port's backend whenever a session is live;
nothing extra needs to be bound in `port-mode`.

All output, including evaluation results from source buffers, ends up in the
REPL buffer.

## Tap support

Values published via `tap>` show up in two places: a one-line preview in the
REPL buffer, and the dedicated `*port-taps*` history buffer, which keeps the
full pretty-printed values for browsing. Use `C-c C-t v` to pop the history
buffer and `C-c C-t c` to clear it. The buffer is capped at
`port-tap-max-entries` (default 100), oldest entry dropped on overflow.

When Port jacks in the JVM itself, it configures `io-prepl` with a
`clojure.pprint`-based `:valf`, so `:ret` and `:tap` values arrive
pretty-printed already. Set `port-jack-in-pretty-print` to nil to opt out.

## Running tests

Port can drive `clojure.test` over the tool socket and render the
results in a `*port-test-report*` buffer. The four entry points:

| Binding     | Command                     | What it runs                       |
|-------------|-----------------------------|------------------------------------|
| `C-c C-t t` | `port-test-run-at-point`    | The `deftest` enclosing point      |
| `C-c C-t n` | `port-test-run-ns`          | Every `deftest` in the current ns  |
| `C-c C-t p` | `port-test-run-project`     | Every loaded test-bearing namespace |
| `C-c C-t r` | `port-test-rerun-failed`    | Only the vars that failed last run |

The report buffer shows a one-line summary, then a section per
failure/error with `expected:`, `actual:`, and a `file:line` link.
`RET` on a link jumps to the source; on an error's `(RET to show
stacktrace)` line it pops Port's existing structured stacktrace
buffer for the captured `Throwable->map`. `n`/`p` walks failures,
`g` re-runs the same selection, `q` buries the buffer.

The Clojure-side machinery is installed lazily on first use and lives
in `port-test-bootstrap-form`. Each entry point is also exposed as a
defcustom (`port-test-run-ns-form`, `port-test-run-var-form`,
`port-test-run-all-form`, `port-test-rerun-failed-form`) for dialect
or test-runner overrides.

## Dialect support

Port's helper commands send plain Clojure forms over prepl, so any dialect
that exposes a `clojure.core.server`-style prepl will work. The realistic
candidates today:

| Dialect              | Status       | Notes                                            |
|----------------------|--------------|--------------------------------------------------|
| Clojure (JVM)        | Supported    | Default. All forms target `clojure.repl/*`.       |
| [Babashka][]         | Supported    | Drop-in. `source` on built-ins needs bb ≥ 1.12.216. |
| [ClojureCLR][]       | Supported    | 1:1 port of `clojure.core.server`.                |
| [ClojureScript][cljs] | Experimental | `cljs.core.server/io-prepl` exists, but the ecosystem is on piggieback+nREPL. Use the override defcustoms. |

Other dialects (basilisp, jank, Planck, nbb) don't ship prepl; their
supported editor path is nREPL.

Every Clojure form Port sends is held in a `defcustom`, so you can override
it for a dialect, a different introspection library, or your own
preferences. The full list:

| Defcustom                  | Sent by                       |
|----------------------------|-------------------------------|
| `port-doc-form`            | `port-doc`                    |
| `port-source-form`         | `port-source`                 |
| `port-apropos-form`        | `port-apropos`                |
| `port-macroexpand-1-form`  | `port-macroexpand-1`          |
| `port-macroexpand-all-form`| `port-macroexpand`            |
| `port-load-file-form`      | `port-load-file`              |
| `port-set-ns-form`         | `port-set-ns`                 |
| `port-eldoc-form`          | eldoc-at-point                |
| `port-completion-form`     | `completion-at-point`         |
| `port-xref-form`           | `xref-find-definitions` (`M-.`) |
| `port-xref-apropos-form`   | `xref-find-apropos`           |
| `port-test-run-ns-form`    | `port-test-run-ns`            |
| `port-test-run-var-form`   | `port-test-run-at-point`      |
| `port-test-run-all-form`   | `port-test-run-project`       |
| `port-test-rerun-failed-form` | `port-test-rerun-failed`   |

For example, to point `port-doc` at ClojureScript:

```elisp
(setq port-doc-form    "(with-out-str (cljs.repl/doc %s))"
      port-source-form "(with-out-str (cljs.repl/source %s))")
```

Each defcustom's docstring documents what its `%s` / `%S` placeholders
resolve to.

[Babashka]: https://babashka.org
[ClojureCLR]: https://github.com/clojure/clojure-clr
[cljs]: https://clojurescript.org

## Better completion

Port's default `completion-at-point` is a plain `ns-map` walk: it sees
vars visible in the buffer's namespace and nothing else. For locals,
classes, keywords, Java methods, and the rest, two paths are worth
knowing about.

**Recommended: clojure-lsp.** Add `clojure-lsp` to your editor setup
(via [`eglot`](https://www.gnu.org/software/emacs/manual/html_mono/eglot.html)
or [`lsp-mode`](https://emacs-lsp.github.io/lsp-mode/)) and let it own
completion. clojure-lsp does static analysis on the project, so it
works without a running prepl and gives much richer candidates than
anything Port can scrape at runtime. This is the path most Port users
should take.

**Alternative: Compliment-on-the-classpath.** If your project pulls in
[Compliment](https://github.com/alexander-yakushev/compliment) (any
project that depends on `cider-nrepl` transitively does), you can swap
Port's completion form to call it:

```elisp
(require 'port-orchard)
(setq port-completion-form port-compliment-completion-form)
```

or interactively via `M-x port-enable-orchard` (see below).

## Richer introspection via Orchard

[Orchard](https://github.com/clojure-emacs/orchard) is the Clojure
introspection library CIDER uses for doc / info lookup, eldoc, find-
definition, and apropos. When Orchard is on the running JVM's
classpath, Port can route its helper commands through `orchard.info`
and friends for noticeably better results: Java member info,
namespace-alias resolution, ClojureDocs `See also`, and jar / Java-
source file location handling that the default `clojure.repl/*` forms
don't get.

### Step 1: get Orchard and Compliment onto the classpath

Orchard and Compliment aren't part of Clojure proper, so you need to
pull them in.  Three options, increasing in convenience:

**Easiest: let `M-x port` inject them.**  Set:

```elisp
(setq port-jack-in-extra-deps port-jack-in-orchard-deps)
```

and `M-x port` (alias `M-x port-jack-in`) splices `-Sdeps '{...}'`
into the tools-deps invocation, or chained
`update-in :dependencies conj` calls into the Leiningen one.  No
project-side changes needed.  This is the fastest path if you don't
care about the rest of your team — the deps only exist in the JVM
Port spawned, not in your `deps.edn` / `project.clj`.

The other two paths add the deps to the project, which is useful if
you want them available outside Port too, or if you're already
running a prepl externally and using `M-x port-connect`.

**deps.edn alias** (committed; visible to teammates):

```elisp
;; project's deps.edn

```clojure
{:aliases
 {:port-tools {:extra-deps {cider/orchard         {:mvn/version "0.41.0"}
                            compliment/compliment {:mvn/version "0.8.0"}}}}}
```

Then start the prepl with the alias active:

```
clojure -A:port-tools \
  -X clojure.core.server/start-server \
  :name '"port"' :port 5555 \
  :accept clojure.core.server/io-prepl
```

and `M-x port-connect`.

**Leiningen** (`project.clj`):

```clojure
:profiles
{:port-tools {:dependencies [[cider/orchard         "0.41.0"]
                             [compliment/compliment "0.8.0"]]}}
```

Then:

```
lein with-profile +port-tools trampoline run -m clojure.main -e \
  "(do (clojure.core.server/start-server {:name \"port\" :port 5555 :accept (quote clojure.core.server/io-prepl)}) @(promise))"
```

and `M-x port-connect`.

Port's `M-x port` jack-in doesn't yet read custom aliases / profiles
out of the box (it's on the roadmap).  If you've put the deps in an
alias rather than using `port-jack-in-extra-deps`, you can either
start the prepl externally as above, or invoke `M-x port` with a
prefix argument (`C-u M-x port`) to edit the spawned command and add
`-A:port-tools` / `with-profile +port-tools` by hand.

### Step 2: enable the Orchard-flavored forms

**Interactive:** with a Port session live, run `M-x port-enable-orchard`.
It probes the tool socket for `orchard.info` and `compliment.core`,
then swaps the relevant `port-*-form` defcustoms for the available
half.  Probes are independent: if you have Orchard but not Compliment
(or vice versa) you'll get whichever is loadable.

**Auto on every connect:** set `port-enable-orchard-on-connect` and
the probe + swap fires after each `M-x port` / `M-x port-connect`
automatically.  Pairs naturally with `port-jack-in-extra-deps`:

```elisp
(setq port-jack-in-extra-deps          port-jack-in-orchard-deps
      port-enable-orchard-on-connect   t)
```

**Per-form persistent:** if you'd rather hard-wire the form templates
in your init (no probe, no dependency on `port-after-connect-hook`):

```elisp
(require 'port-orchard)
(setq port-doc-form        port-orchard-doc-form
      port-eldoc-form      port-orchard-eldoc-form
      port-apropos-form    port-orchard-apropos-form
      port-xref-form       port-orchard-xref-form
      port-completion-form port-compliment-completion-form)
```

Orchard is JVM-only — it won't load on Babashka or ClojureCLR.  The
probe-based interactive command degrades gracefully there (it just
reports nothing was enabled).

## Architecture

prepl has no built-in request id, so any tooling that needs to know which
response belongs to which request has to layer that on top. Port does it by
opening **two** prepl connections per session:

- a **user socket** that drives the REPL buffer with raw streaming output,
- a **tool socket** that carries helper-command requests (doc, source,
  macroexpand, ...) wrapped in a small bootstrap function that captures
  `*out*` / `*err*` and returns a tagged map containing the request id.

The bootstrap (`port.tooling/-eval`) is sent once on connect; subsequent
helper calls go through it and dispatch back to per-request callbacks via the
request id. The user socket stays clean (no wrapping, no surprises), so
direct evals from a Clojure buffer behave like typing into the REPL.

For the deeper rationale and a walkthrough of each module, see
[`doc/design.md`](doc/design.md).

## Limitations (today)

- No inline overlays or debugger. (The tool socket makes both tractable;
  they're just not implemented yet.)

## FAQ

### Why is it called Port?

Two reasons. I started this project while spending some time in Porto, and
there's already a tradition of naming Clojure-on-editor tools after drinks:
[CIDER][], [Calva][] (after Calvados, the Norman apple brandy). Port wine
fit, and the protocol is `prepl` over a TCP **port**, so the pun was hard to
pass up.

[Calva]: https://calva.io

## License

Distributed under the GNU General Public License, version 3 or later.

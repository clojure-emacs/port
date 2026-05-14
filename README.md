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
  and `M-.` find-definition that follows into jar sources.
- Dedicated `*port-taps*` buffer that accumulates values published via
  `tap>`, with `C-c C-t v` to view and `C-c C-t c` to clear.

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
| `M-.`     | `port-find-definition`        |

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
| `port-xref-form`           | `port-find-definition` (`M-.`) |

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

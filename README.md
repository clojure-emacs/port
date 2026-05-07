# Port

A minimalist Clojure interactive programming environment for Emacs, in the
spirit of [CIDER](https://github.com/clojure-emacs/cider) and
[monroe](https://github.com/sanel/monroe), built on top of Clojure's built-in
[prepl](https://clojure.org/reference/repl_and_main#prepl) instead of nREPL.

> Status: prototype / MVP. Expect rough edges.

## Why prepl?

prepl (`clojure.core.server/io-prepl`) is a streaming text protocol that ships
with Clojure itself. There is no bencode, no middleware, no sessions — just
send a Clojure form and read back a sequence of EDN messages tagged `:ret`,
`:out`, `:err`, or `:tap`. That makes Port small, portable, and easy to reason
about, at the cost of features that nREPL middleware would otherwise provide.

Where CIDER asks the server (via middleware) for things like documentation or
completion, Port follows monroe's lead and implements such commands by simply
evaluating a Clojure form (e.g. `(clojure.repl/doc foo)`) and printing the
result into the REPL buffer.

## How does it compare to other Clojure tools for Emacs?

The Clojure-on-Emacs landscape can be thought of as a ladder where each rung
adds structure to how the editor talks to a running Clojure. Roughly:

| Tool             | Protocol                              | Server-side deps              |
|------------------|---------------------------------------|-------------------------------|
| [inf-clojure][]  | comint over stdio (or a socket REPL)  | none                          |
| **Port**         | prepl (TCP)                           | none — built into Clojure     |
| [monroe][]       | nREPL                                 | nREPL                         |
| [CIDER][]        | nREPL + cider-nrepl middleware        | nREPL + cider-nrepl           |

**inf-clojure** sits closest to the metal: it runs a Clojure (or babashka,
Planck, …) subprocess under Emacs's [`comint`][comint] and parses its
plain-text output.  Helper commands like documentation and arglist lookup are
implemented by sending predefined code snippets to the REPL and reading what
the REPL prints back.  Universal and cheap — but the lack of structured output
means the editor can't always tell apart a return value, stdout, and an error.

**Port** is one rung up.  prepl is a tiny TCP protocol that ships with Clojure
itself; instead of plain text it emits tagged EDN messages (`:ret`, `:out`,
`:err`, `:tap`, `:exception`).  That structure is enough to build reliable
tooling on top, once you add a small bootstrap form for request/response
correlation (see [`doc/design.md`](doc/design.md)).  Helper commands are still
implemented by sending Clojure forms — same idea as inf-clojure — but Port
can tell which response goes with which request without scraping prose.

**monroe** is another rung up.  It uses [nREPL][], whose protocol provides
sessions, ops, and request ids out of the box.  The editor side stays small
because nREPL gives it those primitives for free.  No middleware required
beyond plain nREPL.

**CIDER** is the maximalist rung: nREPL plus the [cider-nrepl][] middleware
suite plus a substantial editor codebase.  The middleware provides
server-side support for features that aren't cheap to build on bare nREPL —
debugger, inspector, test runner, profiler, structured stacktrace browser,
refactoring.  Heavier setup, vastly more features.

A useful way to read the ladder: **the bulk of each project lives wherever its
protocol has the gaps**.  inf-clojure is small because `comint` already
exists.  monroe is small because nREPL already gives it primitives.  Port has
to be slightly bigger than monroe — the two-socket model, the bootstrap —
because prepl gives it less.  CIDER's bulk mostly isn't even Emacs Lisp; it's
`cider-nrepl`, server-side, because that's where nREPL is meant to be
extended.

Pick the rung you actually want: maximum power → CIDER; small structured
client over prepl → Port; small client over nREPL → monroe; zero server-side
requirements → inf-clojure.

[inf-clojure]: https://github.com/clojure-emacs/inf-clojure
[monroe]: https://github.com/sanel/monroe
[CIDER]: https://github.com/clojure-emacs/cider
[nREPL]: https://nrepl.org
[cider-nrepl]: https://github.com/clojure-emacs/cider-nrepl
[comint]: https://www.masteringemacs.org/article/comint-writing-command-interpreter

## Architecture

prepl has no built-in request id, so any tooling that needs to know which
response belongs to which request has to layer that on top. Port does it by
opening **two** prepl connections per session:

- a **user socket** that drives the REPL buffer with raw streaming output,
- a **tool socket** that carries helper-command requests (doc, source,
  macroexpand, …) wrapped in a small bootstrap function that captures
  `*out*` / `*err*` and returns a tagged map containing the request id.

The bootstrap (`port.tooling/-eval`) is sent once on connect; subsequent
helper calls go through it and dispatch back to per-request callbacks via
the request id. The user socket stays clean — no wrapping, no surprises —
so direct evals from a Clojure buffer behave like typing into the REPL.

## Starting a prepl

The simplest path is to let Port spawn one for you: visit a file in your
project and run `M-x port`.  It auto-detects the project layout (`deps.edn`
or `project.clj`), picks a free port in `5555-5574`, starts a JVM with a
prepl server on that port, and connects when it's ready.  The server's
stdout/stderr lands in a `*port-server*` buffer below the REPL.

If you'd rather run the prepl yourself (handy for embedding it in a
long-running application or pre-warming the JVM), start it like this:

```
clojure -e '(do (clojure.core.server/start-server
                  {:name "port" :port 5555
                   :accept (quote clojure.core.server/io-prepl)})
                @(promise))'
```

and then `M-x port-connect` to attach.

## Installation

Port isn't on MELPA yet (it might be once it's stable enough for a real
release).  In the meantime, the easiest way is `package-vc-install` on
Emacs 29+:

```elisp
(package-vc-install
 '(port :url "https://github.com/clojure-emacs/port"
        :branch "main"))
```

If you use [`use-package`](https://github.com/jwiegley/use-package) on Emacs
30+ you can put the same thing in your config and let it handle install:

```elisp
(use-package port
  :vc (:url "https://github.com/clojure-emacs/port" :branch "main")
  :hook (clojure-mode . port-mode))
```

For a manual checkout (e.g. while contributing):

```elisp
(add-to-list 'load-path "/path/to/port/lisp")
(require 'port)
(add-hook 'clojure-mode-hook #'port-mode)
```

## Connecting from Emacs

For most projects `M-x port` is all you need — it starts a prepl and
connects.  Use `M-x port-connect` (default `localhost:5555`) when you've
started a prepl yourself or want to attach to one running elsewhere.

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
| `M-.`     | `port-find-definition`        |

All output, including evaluation results from source buffers, is written to
the REPL buffer.

## Limitations (today)

- No `port-jack-in`; you start the prepl yourself.
- No inline overlays or debugger. (The tool socket makes these
  tractable; they're just not implemented yet.)
- No structured error rendering; stacktraces print as the server emits them.
- No persistent input history.

## Design

For the architecture, the rationale behind the two-socket model, and a
walkthrough of how each piece fits together, see
[`doc/design.md`](doc/design.md).

## License

Distributed under the GNU General Public License, version 3 or later.

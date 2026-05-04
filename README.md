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

From your project, run:

```
clj -X clojure.core.server/start-server \
    :name '"port"' :port 5555 \
    :accept clojure.core.server/io-prepl
```

You can also embed an equivalent `start-server` call into your application's
`-main`, or wire it up via a `deps.edn` alias.

## Connecting from Emacs

```elisp
(add-to-list 'load-path "/path/to/port/lisp")
(require 'port)
(add-hook 'clojure-mode-hook #'port-mode)
```

Then `M-x port-connect`, accept the default `localhost:5555`, and a REPL
buffer pops up.

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

## License

Distributed under the GNU General Public License, version 3 or later.

# Changelog

## 0.1.0-snapshot (unreleased)

Initial prototype.

- TCP prepl client with a small EDN-ish reader.
- Two-socket session model: a user socket drives the REPL with raw
  streaming output, and a separate tool socket carries helper-command
  requests with reliable request/response correlation via a small
  `port.tooling/-eval` bootstrap.
- Eldoc support: arglists for the function whose call surrounds point,
  resolved on the tool socket and delivered asynchronously via
  `eldoc-documentation-functions`.
- Single-buffer REPL that renders `:ret`, `:out`, `:err`, and `:tap`
  messages.
- Interactive eval commands: last-sexp, defun-at-point, region, buffer.
- Helper commands powered by Clojure evaluation: doc, source, apropos,
  macroexpand-1, macroexpand, load-file, set-ns.
- `port-mode` minor mode for Clojure source buffers.

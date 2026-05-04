# Changelog

## 0.1.0-snapshot (unreleased)

Initial prototype.

- TCP prepl client with a small EDN-ish reader.
- Single-buffer REPL that renders `:ret`, `:out`, `:err`, and `:tap` messages.
- Interactive eval commands: last-sexp, defun-at-point, region, buffer.
- Helper commands powered by Clojure evaluation: doc, source, apropos,
  macroexpand-1, macroexpand, load-file, set-ns.
- `port-mode` minor mode for Clojure source buffers.

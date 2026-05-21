;;; port-tooling.el --- Request/response correlation over a tool socket -*- lexical-binding: t -*-

;; Copyright © 2026 Bozhidar Batsov and Port contributors

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; prepl is a streaming protocol with no built-in request id, so any
;; tool that needs to know which message belongs to which request has
;; to layer that on top.  Port does it by opening a second prepl
;; connection (the "tool socket"), sending a one-shot bootstrap form
;; that defines `port.tooling/-eval', and routing helper commands
;; through it.  The wrapper captures *out* / *err* and returns a
;; tagged map containing the request id, so the client can match each
;; response to a pending callback.

;;; Code:

(require 'port-client)
(require 'port-session)

(defcustom port-print-length 50
  "Maximum sequence length to print in an interactive eval result.
Sequences longer than this are truncated with `...' in the value
shown in the REPL or minibuffer.  Set to nil for no limit.
Internally this is bound to Clojure's *print-length* dynamic var.

This only affects the tool-socket path (the default for
`port-eval-display').  Values printed by io-prepl on the user
socket use the server's defaults."
  :type '(choice integer (const :tag "Unlimited" nil))
  :group 'port)

(defcustom port-print-level 5
  "Maximum nesting depth to print in an interactive eval result.
Nested structures deeper than this are abbreviated with `#'.
Set to nil for no limit.  Internally this is bound to Clojure's
*print-level* dynamic var.  See `port-print-length' for scope."
  :type '(choice integer (const :tag "Unlimited" nil))
  :group 'port)

(defconst port-tooling-bootstrap
  "(do (clojure.core/ns port.tooling
         (:require [clojure.pprint]))
       (clojure.core/defn -eval [id thunk]
         (let [out-buf (java.io.StringWriter.)
               err-buf (java.io.StringWriter.)]
           (binding [*out* out-buf *err* err-buf]
             (try
               (let [v (thunk)]
                 {:port/id id :tag :ok :val (pr-str v)
                  :out (str out-buf) :err (str err-buf)})
               (catch Throwable t
                 {:port/id id :tag :err
                  :ex (pr-str (Throwable->map t))
                  :ex-message (or (.getMessage t) (.getName (class t)))
                  :out (str out-buf) :err (str err-buf)})))))
       (clojure.core/defn -data-eval [id thunk]
         (let [out-buf (java.io.StringWriter.)
               err-buf (java.io.StringWriter.)]
           (binding [*out* out-buf *err* err-buf]
             (try
               (let [v (thunk)]
                 {:port/id id :tag :ok :val v
                  :out (str out-buf) :err (str err-buf)})
               (catch Throwable t
                 {:port/id id :tag :err
                  :ex (pr-str (Throwable->map t))
                  :ex-message (or (.getMessage t) (.getName (class t)))
                  :out (str out-buf) :err (str err-buf)})))))
       (clojure.core/defn -user-eval [id ns-sym form-string plen plev]
         (let [out-buf (java.io.StringWriter.)
               err-buf (java.io.StringWriter.)]
           (binding [*out* out-buf *err* err-buf
                     *ns* (or (find-ns ns-sym) (find-ns 'user))
                     *print-length* plen
                     *print-level*  plev]
             (try
               (let [v (eval (read-string (str \"(do\\n\" form-string \"\\n)\")))
                     pp (binding [*print-length* plen *print-level* plev]
                          (clojure.string/trimr
                           (with-out-str (clojure.pprint/pprint v))))]
                 {:port/id id :tag :ok :val pp
                  :out (str out-buf) :err (str err-buf)
                  :ns (str (ns-name *ns*))})
               (catch Throwable t
                 {:port/id id :tag :err
                  :ex (pr-str (Throwable->map t))
                  :ex-message (or (.getMessage t) (.getName (class t)))
                  :out (str out-buf) :err (str err-buf)}))))))"
  "Clojure form sent on the tool socket on connect.
Defines three wrappers in the `port.tooling' namespace:

- `-eval' (used by `port-tooling-call'): the historical path.
  Pr-str's the return value into `:val', so callers that just
  want a printed string for display (e.g. `port-doc',
  `port-source') get exactly what `pr-str' produces.

- `-data-eval' (used by `port-tooling-call-data'): leaves the
  return value unprinted, letting prepl's outer `prn' do a single
  serialization pass.  Saves an entire EDN re-parse on the Elisp
  side for tooling responses (completion, xref, eldoc, etc.)
  whose payloads we'd just parse again with
  `port-tooling-decode-val' under the old path.  Only safe for
  forms whose result is EDN-readable; arbitrary Java objects
  should go through `-eval'.

- `-user-eval': the namespace-aware variant used for interactive
  evaluation from source buffers; pretty-prints under
  caller-supplied `*print-length*' / `*print-level*' caps.")

(defun port-tooling-install (session)
  "Install the tool-socket handler on SESSION and send the bootstrap form."
  (let ((conn (port-session-tool-conn session)))
    (setf (port-client-handler conn)
          (lambda (_conn msg)
            (port-tooling--dispatch session msg)))
    (port-client-send conn port-tooling-bootstrap)))

(defun port-tooling-call (session form-string callback)
  "Evaluate FORM-STRING on SESSION's tool socket.
CALLBACK is invoked with the result alist, which has keys
`:port/id', `:tag' (`:ok' or `:err'), `:val' (printed return value
when `:ok'), `:ex' (printed Throwable->map when `:err'),
`:ex-message' (just the exception's message when `:err'), `:out',
`:err'.  Returns the allocated request id so a sync caller can
evict a stale callback on timeout."
  (port-tooling--call session form-string callback "-eval"))

(defun port-tooling-call-data (session form-string callback)
  "Evaluate FORM-STRING on SESSION's tool socket, returning raw data.
Like `port-tooling-call', but `:val' arrives already parsed into
its Elisp representation rather than as a `pr-str''d string.
Saves a full EDN re-parse on the Elisp side and avoids the
escape-doubling that `pr-str' inflicts on nested strings; for the
completion warm-up's ~100 KB ns-map response that's a 2-3x
speedup.  Use this when FORM-STRING returns EDN-readable data
\(vectors, maps, strings, keywords, numbers); use the plain
`port-tooling-call' for forms whose result might be a Java object
or anything else not safely round-trippable."
  (port-tooling--call session form-string callback "-data-eval"))

(defun port-tooling--call (session form-string callback wrapper)
  "Common dispatch for `port-tooling-call' and `port-tooling-call-data'.
WRAPPER is the unqualified Clojure function name (`-eval' or
`-data-eval') to wrap FORM-STRING in before sending."
  (let* ((id (port-session-next-id! session))
         (wrapped (format "(port.tooling/%s %d (fn [] %s))"
                          wrapper id form-string)))
    (port-session-register-callback session id callback)
    (port-client-send (port-session-tool-conn session) wrapped)
    id))

(defun port-tooling-user-eval (session ns code callback)
  "Evaluate CODE in namespace NS on SESSION's tool socket.
NS is a Clojure namespace name as a string or symbol; if it can't
be resolved on the JVM side, evaluation falls back to the `user'
namespace.  CODE is a Clojure source string, possibly containing
several top-level forms (the wrapper splices them into a `do').
The returned value is pretty-printed under `port-print-length' /
`port-print-level' caps before being delivered.  CALLBACK is
invoked with the parsed result alist (same shape as
`port-tooling-call', plus `:ns' on success)."
  (let* ((id (port-session-next-id! session))
         (wrapped (format "(port.tooling/-user-eval %d (quote %s) %S %s %s)"
                          id ns code
                          (port-tooling--clj-int port-print-length)
                          (port-tooling--clj-int port-print-level))))
    (port-session-register-callback session id callback)
    (port-client-send (port-session-tool-conn session) wrapped)))

(defun port-tooling--clj-int (n)
  "Render N as a Clojure literal: an integer or the string \"nil\"."
  (if (integerp n) (number-to-string n) "nil"))

(defun port-tooling-call-sync (session form-string &optional timeout)
  "Like `port-tooling-call' on SESSION, but block until a response arrives.
FORM-STRING is the Clojure form.  TIMEOUT defaults to 2 seconds.
Returns the result alist, or nil on timeout.  Suitable for use
from a `completion-at-point-functions' member, where the
surrounding API is synchronous."
  (port-tooling--call-sync session form-string timeout #'port-tooling-call))

(defun port-tooling-call-data-sync (session form-string &optional timeout)
  "Blocking variant of `port-tooling-call-data'.
Same semantics as `port-tooling-call-sync' but `:val' arrives as
parsed data rather than a printed string.  Used by `port-xref'
to drive the synchronous `xref-find-definitions' lookup."
  (port-tooling--call-sync session form-string timeout
                           #'port-tooling-call-data))

(defun port-tooling--call-sync (session form-string timeout call-fn)
  "Shared sync-call body.  CALL-FN is `port-tooling-call' or its data variant."
  (let* ((done nil)
         (result nil)
         (deadline (+ (float-time) (or timeout 2.0)))
         (proc (port-client-process (port-session-tool-conn session)))
         (id (funcall call-fn session form-string
                      (lambda (r) (setq result r) (setq done t)))))
    (while (and (not done) (< (float-time) deadline))
      (accept-process-output proc 0.05))
    (unless done
      ;; Pending alist would otherwise hold the callback forever; a
      ;; late response would still fire it harmlessly, but the entry
      ;; is now stale.
      (port-session-pop-callback session id))
    (and done result)))

(defun port-tooling--dispatch (session msg)
  "Look at MSG arriving on SESSION's tool socket and fire matching callback."
  (when (eq (alist-get :tag msg) :ret)
    (when-let* ((val (alist-get :val msg))
                (parsed (port-tooling--read-result val))
                (id (alist-get :port/id parsed))
                (cb (port-session-pop-callback session id)))
      (funcall cb parsed))))

(defun port-tooling--read-result (val-string)
  "Parse VAL-STRING into an alist, or nil if it isn't a map.
VAL-STRING is the printed result map from `port.tooling/-eval'.
Non-map values (e.g. the var ref `#'port.tooling/-eval' returned
by the bootstrap form itself) parse to a stray symbol; we filter
those out so callers can do simple non-nil checks."
  (condition-case _
      (let ((parsed (car (port-client--read val-string 0))))
        (and (consp parsed) (consp (car parsed)) parsed))
    (error nil)))

(defun port-tooling-decode-val (val)
  "Decode VAL — a printed Clojure value as it appears in a result map's `:val'.
For a printed string return the unwrapped string; for nil, a number,
keyword, or map return the corresponding Elisp value.  Return VAL
unchanged if it can't be parsed."
  (if (stringp val)
      (condition-case _
          (car (port-client--read val 0))
        (error val))
    val))

(provide 'port-tooling)

;;; port-tooling.el ends here

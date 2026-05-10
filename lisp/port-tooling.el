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

(defconst port-tooling-bootstrap
  "(do (clojure.core/ns port.tooling)
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
                  :out (str out-buf) :err (str err-buf)}))))))"
  "Clojure form sent on the tool socket on connect.
Defines `port.tooling/-eval', the wrapper used by `port-tooling-call'.")

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
when `:ok'), `:ex' (printed Throwable->map when `:err'), `:out',
`:err'."
  (let* ((id (port-session-next-id! session))
         (wrapped (format "(port.tooling/-eval %d (fn [] %s))" id form-string)))
    (port-session-register-callback session id callback)
    (port-client-send (port-session-tool-conn session) wrapped)))

(defun port-tooling-call-sync (session form-string &optional timeout)
  "Like `port-tooling-call' but block until the response arrives.
TIMEOUT defaults to 2 seconds.  Returns the result alist, or nil on
timeout.  Suitable for use from a `completion-at-point-functions'
member, where the surrounding API is synchronous."
  (let* ((done nil)
         (result nil)
         (deadline (+ (float-time) (or timeout 2.0)))
         (proc (port-client-process (port-session-tool-conn session))))
    (port-tooling-call session form-string
                       (lambda (r) (setq result r) (setq done t)))
    (while (and (not done) (< (float-time) deadline))
      (accept-process-output proc 0.05))
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
For a printed string returns the unwrapped string; for `nil', a number,
keyword, or map returns the corresponding Elisp value.  Returns VAL
unchanged if it can't be parsed."
  (if (stringp val)
      (condition-case _
          (car (port-client--read val 0))
        (error val))
    val))

(provide 'port-tooling)

;;; port-tooling.el ends here

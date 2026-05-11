;;; port-session.el --- Session abstraction with user + tool sockets -*- lexical-binding: t -*-

;; Copyright © 2026 Bozhidar Batsov and Port contributors

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A `port-session' bundles two independent prepl connections to the
;; same server: a user socket that drives the REPL buffer with raw
;; streaming output, and a tool socket that carries correlated
;; helper-command requests via the `port-tooling' bootstrap.

;;; Code:

(require 'cl-lib)
(require 'port-client)

(cl-defstruct (port-session
               (:constructor port-session--make)
               (:copier nil))
  "A live Port session — two connections, one REPL buffer."
  host
  port
  user-conn
  tool-conn
  repl-buffer
  jvm-process            ; non-nil when this session was started via `M-x port'
  (next-id 0)
  (pending '()))

(defvar port-default-session nil
  "The most recently established session.")

(defun port-current-session ()
  "Return the active session or signal a user error."
  (or port-default-session
      (user-error "Port: not connected; run `M-x port-connect' first")))

(defun port-session-current-ns (session)
  "Return SESSION's user-socket tracked namespace as a string.
Falls back to \"user\" when the socket has no namespace yet."
  (or (port-client-current-ns (port-session-user-conn session))
      "user"))

(defun port-symbol-at-point ()
  "Return the symbol at point as a string with no text properties.
A small shared helper so the various interactive commands don't
each define their own copy.  Returns nil when nothing is at point."
  (when-let ((s (thing-at-point 'symbol t)))
    (substring-no-properties s)))

(defun port-session-next-id! (session)
  "Allocate and return the next request id for SESSION."
  (cl-incf (port-session-next-id session)))

(defun port-session-register-callback (session id callback)
  "Register CALLBACK to fire when a tool result with ID arrives on SESSION."
  (push (cons id callback) (port-session-pending session)))

(defun port-session-pop-callback (session id)
  "Remove and return the callback for ID on SESSION, or nil."
  (let ((entry (assq id (port-session-pending session))))
    (when entry
      (setf (port-session-pending session)
            (assq-delete-all id (port-session-pending session)))
      (cdr entry))))

(defun port-session-shutdown (session)
  "Tear down both connections of SESSION, and the JVM if we spawned it."
  (when (port-session-user-conn session)
    (port-client-disconnect (port-session-user-conn session)))
  (when (port-session-tool-conn session)
    (port-client-disconnect (port-session-tool-conn session)))
  (when-let ((proc (port-session-jvm-process session)))
    (when (process-live-p proc)
      (delete-process proc)))
  (setf (port-session-pending session) nil)
  (when (eq port-default-session session)
    (setq port-default-session nil)))

(provide 'port-session)

;;; port-session.el ends here

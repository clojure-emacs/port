;;; port-jack-in.el --- Start a prepl in the current project and connect to it -*- lexical-binding: t -*-

;; Copyright © 2026 Bozhidar Batsov and Port contributors

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; SLIME-style jack-in: `M-x port' detects the project type, picks a
;; free port, spawns a JVM that runs a prepl server alongside an
;; ever-blocking main thread, polls until the port is reachable, and
;; then connects to it via `port-connect'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'port-client)
(require 'port-session)

(defcustom port-jack-in-clojure-program "clojure"
  "Command used to launch the Clojure CLI."
  :type 'string :group 'port)

(defcustom port-jack-in-leiningen-program "lein"
  "Command used to launch Leiningen."
  :type 'string :group 'port)

(defcustom port-jack-in-startup-timeout 30
  "Seconds to wait for the prepl server to start accepting connections."
  :type 'number :group 'port)

(defcustom port-jack-in-port-range '(5555 . 5574)
  "Inclusive cons (LOW . HIGH) of ports to scan for a free one."
  :type '(cons integer integer) :group 'port)

(defun port-jack-in--detect-project-root ()
  "Walk up from `default-directory' looking for a Clojure project marker.
Return the project root or `default-directory' if no marker is found."
  (or (locate-dominating-file default-directory "deps.edn")
      (locate-dominating-file default-directory "project.clj")
      (locate-dominating-file default-directory "bb.edn")
      default-directory))

(defun port-jack-in--detect-project-type (root)
  "Return one of `tools-deps', `leiningen', `babashka', or `bare' for ROOT."
  (cond
   ((file-exists-p (expand-file-name "deps.edn"    root)) 'tools-deps)
   ((file-exists-p (expand-file-name "project.clj" root)) 'leiningen)
   ((file-exists-p (expand-file-name "bb.edn"      root)) 'babashka)
   (t 'bare)))

(defun port-jack-in--port-free-p (port)
  "Return non-nil if nothing is currently listening on 127.0.0.1:PORT."
  (let ((proc (condition-case _
                  (make-network-process
                   :name "port-jack-in-probe"
                   :host "127.0.0.1" :service port
                   :nowait nil :noquery t)
                (error nil))))
    (if proc (progn (delete-process proc) nil) t)))

(defun port-jack-in--free-port ()
  "Return the lowest free port in `port-jack-in-port-range'."
  (let* ((lo (car port-jack-in-port-range))
         (hi (cdr port-jack-in-port-range))
         (p  lo))
    (while (and (<= p hi) (not (port-jack-in--port-free-p p)))
      (setq p (1+ p)))
    (if (<= p hi) p
      (user-error "Port: no free ports in %d-%d" lo hi))))

(defun port-jack-in--server-form (port)
  "Return the Clojure -e form that starts a prepl on PORT and blocks."
  (format
   (concat "(do (clojure.core.server/start-server"
           " {:name \"port\" :port %d"
           "  :accept (quote clojure.core.server/io-prepl)})"
           " @(promise))")
   port))

(defun port-jack-in--build-command (project-type port)
  "Return a list (PROGRAM ARG ...) to spawn the JVM for PROJECT-TYPE on PORT."
  (let ((form (port-jack-in--server-form port)))
    (pcase project-type
      ((or 'tools-deps 'bare)
       (list port-jack-in-clojure-program "-e" form))
      ('leiningen
       (list port-jack-in-leiningen-program
             "trampoline" "run" "-m" "clojure.main" "-e" form))
      ('babashka
       (user-error "Port: babashka jack-in is not yet supported"))
      (_ (error "Port: unknown project type %S" project-type)))))

(defun port-jack-in--wait-for-port (port timeout)
  "Block until 127.0.0.1:PORT accepts connections, or TIMEOUT seconds elapse.
Return non-nil on success."
  (let ((deadline (+ (float-time) timeout)))
    (catch 'reachable
      (while (< (float-time) deadline)
        (when (not (port-jack-in--port-free-p port))
          ;; The probe inside port-free-p connected successfully, so the
          ;; server is up.
          (throw 'reachable t))
        (sleep-for 0.2))
      nil)))

(defun port-jack-in--sentinel (proc event)
  "Tear down the session if its JVM PROC dies unexpectedly."
  (when (memq (process-status proc) '(closed exit failed signal))
    (when (and port-default-session
               (eq proc (port-session-jvm-process port-default-session)))
      (message "Port: server process %s; disconnecting" (string-trim event))
      (port-session-shutdown port-default-session))))

(defun port-jack-in--prep-buffer (cmd root)
  "Create and return the *port-server* buffer with CMD and ROOT recorded."
  (let ((buf (get-buffer-create "*port-server*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "; cwd: %s\n; cmd: %s\n\n"
                        root (mapconcat #'identity cmd " "))))
      (special-mode))
    buf))

;;;###autoload
(defun port (&optional edit-command)
  "Start a prepl in the current project and connect to it.
With a prefix arg (EDIT-COMMAND), prompt for the startup command;
the auto-detected one is offered as the default.  If a session is
already active, just pop to the REPL buffer."
  (interactive "P")
  (cond
   (port-default-session
    (pop-to-buffer (port-session-repl-buffer port-default-session)))
   (t
    (let* ((root      (port-jack-in--detect-project-root))
           (default-directory root)
           (type      (port-jack-in--detect-project-type root))
           (port-num  (port-jack-in--free-port))
           (auto-cmd  (port-jack-in--build-command type port-num))
           (cmd       (if edit-command
                          (split-string-shell-command
                           (read-string "Startup command: "
                                        (mapconcat #'shell-quote-argument
                                                   auto-cmd " ")))
                        auto-cmd))
           (buf       (port-jack-in--prep-buffer cmd root))
           (proc      (apply #'make-process
                             :name "port-server"
                             :buffer buf
                             :command cmd
                             :sentinel #'port-jack-in--sentinel
                             :noquery nil
                             nil)))
      (display-buffer buf '(display-buffer-below-selected
                            (window-height . 8)))
      (message "Port: starting %s server on port %d ..." type port-num)
      (cond
       ((port-jack-in--wait-for-port port-num
                                     port-jack-in-startup-timeout)
        (let ((session (port-connect "127.0.0.1" port-num)))
          (setf (port-session-jvm-process session) proc)
          (message "Port: %s session ready on 127.0.0.1:%d" type port-num)))
       (t
        (when (process-live-p proc) (delete-process proc))
        (user-error "Port: server didn't come up within %d seconds"
                    port-jack-in-startup-timeout)))))))

(provide 'port-jack-in)

;;; port-jack-in.el ends here

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
(require 'port-tooling)

(defcustom port-jack-in-clojure-program "clojure"
  "Command used to launch the Clojure CLI."
  :type 'string :group 'port)

(defcustom port-jack-in-leiningen-program "lein"
  "Command used to launch Leiningen."
  :type 'string :group 'port)

(defcustom port-jack-in-babashka-program "bb"
  "Command used to launch Babashka."
  :type 'string :group 'port)

(defcustom port-jack-in-startup-timeout 30
  "Seconds to wait for the prepl server to start accepting connections."
  :type 'number :group 'port)

(defcustom port-jack-in-port-range '(5555 . 5574)
  "Inclusive cons (LOW . HIGH) of ports to scan for a free one."
  :type '(cons integer integer) :group 'port)

(defcustom port-jack-in-pretty-print t
  "When non-nil, pretty-print `:ret' and `:tap' values on the user socket.
The jack-in startup form passes a `clojure.pprint'-based `:valf' to
`io-prepl', so both interactive eval results and tapped values
arrive multi-line and indented.  Has no effect in `port-connect'
mode (where the user controls how the prepl was started)."
  :type 'boolean :group 'port)

(defcustom port-jack-in-extra-deps nil
  "Extra Maven coordinates to add to the spawned JVM at jack-in.
Either nil for none, or an alist of (DEP-SYMBOL . VERSION-STRING)
pairs.  Honoured for `tools-deps' (via `clojure -Sdeps') and
`leiningen' (via chained `update-in :dependencies conj') projects;
ignored for babashka.

The most common use is enabling Orchard / Compliment on the
classpath so `M-x port-enable-orchard' has something to swap in:

  (setq port-jack-in-extra-deps port-jack-in-orchard-deps)

See `port-jack-in-orchard-deps' for the current preset."
  :type '(choice (const :tag "None" nil)
                 (alist :key-type symbol :value-type string))
  :group 'port)

(defconst port-jack-in-orchard-deps
  '((cider/orchard         . "0.41.0")
    (compliment/compliment . "0.8.0"))
  "Reusable preset for `port-jack-in-extra-deps'.
Adds Orchard and Compliment at the versions known to work with
`port-orchard.el''s form templates.  Pinned rather than
`RELEASE'-floating so a flaky upstream release can't break
jack-in.")

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
  "Return the Clojure `-e' form to start a prepl on PORT and block.
It starts an io-prepl server and parks on a never-delivered promise
so the JVM doesn't exit when the main thread returns.  When
`port-jack-in-pretty-print' is non-nil the server is configured with
a `clojure.pprint'-based `:valf', bounded by `port-print-length' /
`port-print-level', for nicer `:ret' and `:tap' output."
  (if port-jack-in-pretty-print
      (format
       (concat "(do (require 'clojure.pprint 'clojure.string)"
               " (clojure.core.server/start-server"
               " {:name \"port\" :port %d"
               "  :accept (quote clojure.core.server/io-prepl)"
               "  :args [:valf (fn [v]"
               "                 (binding [*print-length* %s"
               "                           *print-level*  %s]"
               "                   (clojure.string/trimr"
               "                    (with-out-str (clojure.pprint/pprint v)))))]})"
               " @(promise))")
       port
       (port-tooling--clj-int port-print-length)
       (port-tooling--clj-int port-print-level))
    (format
     (concat "(do (clojure.core.server/start-server"
             " {:name \"port\" :port %d"
             "  :accept (quote clojure.core.server/io-prepl)})"
             " @(promise))")
     port)))

(defun port-jack-in--deps-edn (deps)
  "Render DEPS (an alist) as a Clojure deps map string.
Each (SYM . VER) pair becomes `SYM {:mvn/version \"VER\"}'."
  (concat "{"
          (mapconcat (lambda (cell)
                       (format "%s {:mvn/version %S}"
                               (car cell) (cdr cell)))
                     deps " ")
          "}"))

(defun port-jack-in--lein-deps-args (deps)
  "Build Leiningen's chained `update-in :dependencies conj' args for DEPS.
Returns a list of argv elements to splice in before the run command."
  (mapcan (lambda (cell)
            (list "update-in" ":dependencies" "conj"
                  (format "[%s \"%s\"]" (car cell) (cdr cell))
                  "--"))
          deps))

(defun port-jack-in--build-command (project-type port)
  "Return a list (PROGRAM ARG ...) to spawn the JVM for PROJECT-TYPE on PORT.
When `port-jack-in-extra-deps' is non-nil, its coordinates are
spliced into the command line via `-Sdeps' (tools-deps) or chained
`update-in :dependencies conj' (leiningen)."
  (let ((form (port-jack-in--server-form port))
        (deps port-jack-in-extra-deps))
    (pcase project-type
      ((or 'tools-deps 'bare)
       (append
        (list port-jack-in-clojure-program)
        (when deps
          (list "-Sdeps"
                (format "{:deps %s}" (port-jack-in--deps-edn deps))))
        (list "-M" "-e" form)))
      ('leiningen
       (append
        (list port-jack-in-leiningen-program)
        (when deps (port-jack-in--lein-deps-args deps))
        (list "trampoline" "run" "-m" "clojure.main" "-e" form)))
      ('babashka
       ;; Babashka supports `clojure.core.server/start-server' + io-prepl
       ;; directly, so the same `--server-form' works.  Extra deps are
       ;; ignored: bb resolves classpath through bb.edn rather than
       ;; inline `-Sdeps' coords.
       (list port-jack-in-babashka-program "-e" form))
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
  "Tear down the session if its JVM PROC dies unexpectedly.
EVENT is the process-state string forwarded from Emacs."
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

;;;###autoload
(defalias 'port-jack-in 'port
  "Alias for `port', the SLIME-style jack-in entry point.
Provided so users coming from CIDER (`cider-jack-in') can find it
under the expected name.")

(provide 'port-jack-in)

;;; port-jack-in.el ends here

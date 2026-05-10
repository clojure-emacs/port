;;; port-repl.el --- REPL buffer mode for Port -*- lexical-binding: t -*-

;; Copyright © 2026 Bozhidar Batsov and Port contributors

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A simple REPL buffer.  All prepl message types (:ret, :out, :err,
;; :tap) are rendered into a single buffer, monroe-style.  The input
;; area lives at the end of the buffer; everything before
;; `port-repl-input-start-marker' is read-only output.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'port-client)
(require 'port-completion)
(require 'port-session)
(require 'port-stacktrace)

(defvar-local port--session nil
  "The `port-session' associated with this REPL buffer.")

(defvar-local port--connection nil
  "The user `port-client' connection associated with this REPL buffer.")

(defvar-local port-repl-input-start-marker nil
  "Marker at the start of the editable input area.")

(defvar-local port-repl-prompt-marker nil
  "Marker just past the most recently inserted prompt.")

(defvar-local port-repl-prompt-active-p nil
  "Non-nil when a live prompt is currently displayed at the end of the buffer.
When nil, output is appended at point-max; when non-nil, it's
inserted above the prompt (preserving any typed-but-unsent input).")

(defvar-local port-repl-history nil
  "Ring of previously sent inputs (most recent first).")

(defvar-local port-repl-history-index -1
  "Current position in `port-repl-history' while browsing.")

(defvar-local port-repl--history-file nil
  "Resolved absolute path of the file backing this buffer's REPL history.")

(defcustom port-repl-history-file nil
  "Where REPL input history is persisted.
If nil, Port writes to .port-history at the project root (or
`default-directory' if no project root can be detected).  If a
string, it is used as the absolute path; the same file is shared
across sessions.  Set to t to disable persistence entirely."
  :type '(choice (const :tag "Per-project (.port-history)" nil)
                 (const :tag "Disabled" t)
                 (file :tag "Specific file"))
  :group 'port)

(defcustom port-repl-history-size 1000
  "Maximum number of REPL history entries to keep on disk and in memory."
  :type 'integer
  :group 'port)

(defface port-repl-prompt-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the REPL prompt."
  :group 'port)

(defface port-repl-stdout-face
  '((t :inherit font-lock-string-face))
  "Face for :out messages."
  :group 'port)

(defface port-repl-stderr-face
  '((t :inherit error))
  "Face for :err messages."
  :group 'port)

(defface port-repl-result-face
  '((t :inherit font-lock-constant-face))
  "Face for :ret values."
  :group 'port)

(defface port-repl-tap-face
  '((t :inherit font-lock-doc-face))
  "Face for :tap messages."
  :group 'port)

(defvar port-repl-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET")     #'port-repl-return)
    (define-key map (kbd "C-c C-c") #'port-repl-interrupt)
    (define-key map (kbd "C-c M-o") #'port-repl-clear-buffer)
    (define-key map (kbd "M-p")     #'port-repl-history-previous)
    (define-key map (kbd "M-n")     #'port-repl-history-next)
    map)
  "Keymap for `port-repl-mode'.")

(define-derived-mode port-repl-mode fundamental-mode "Port-REPL"
  "Major mode for interacting with a Clojure prepl."
  :group 'port
  (setq-local comment-start ";")
  (setq-local indent-tabs-mode nil)
  (set-syntax-table (port-repl--clojure-syntax-table))
  (port-completion-setup))

(defun port-repl--clojure-syntax-table ()
  "Pick the best available Clojure-ish syntax table.
Prefers `clojure-ts-mode' if loaded, then `clojure-mode'; falls
back to `lisp-mode-syntax-table' so the REPL stays usable when
neither is installed."
  (cond
   ((fboundp 'clojure-ts-mode-syntax-table) (clojure-ts-mode-syntax-table))
   ((fboundp 'clojure-mode-syntax-table)    (clojure-mode-syntax-table))
   (t                                       lisp-mode-syntax-table)))

(defun port-repl-create-buffer (session)
  "Create and return a fresh REPL buffer for SESSION."
  (let* ((host (port-session-host session))
         (port (port-session-port session))
         (conn (port-session-user-conn session))
         (name (format "*port-repl: %s:%d*" host port))
         (buf  (get-buffer-create name)))
    (with-current-buffer buf
      (port-repl-mode)
      (setq port--session session)
      (setq port--connection conn)
      (setq port-repl-input-start-marker (make-marker))
      (setq port-repl-prompt-marker (make-marker))
      (setq port-repl--history-file (port-repl--resolve-history-file))
      (port-repl--load-history)
      (add-hook 'kill-buffer-hook #'port-repl--on-kill nil t)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format ";; Port %s connected to %s:%d\n"
                        (or (and (boundp 'port-version) port-version) "")
                        host port)))
      (port-repl--insert-prompt))
    (setf (port-client-handler conn) #'port-repl--connection-handler)
    (setf (port-client-repl-buffer conn) buf)
    (setf (port-session-repl-buffer session) buf)
    buf))

(defun port-repl--on-kill ()
  "Tear down the session when its REPL buffer is killed.
Runs from `kill-buffer-hook'.  Tearing down here ensures that
`C-x k' on the REPL also closes the prepl sockets and kills the
JVM (when we spawned it), so we don't leak processes."
  (when-let* ((session port--session))
    ;; Detach from the connection's repl-buffer slot first so the
    ;; sentinel doesn't try to write a "connection closed" line into
    ;; the buffer that's currently being killed.
    (when-let ((conn (port-session-user-conn session)))
      (setf (port-client-repl-buffer conn) nil))
    (port-session-shutdown session)))

(declare-function port-jack-in--detect-project-root "port-jack-in")

(defun port-repl--resolve-history-file ()
  "Return the absolute path of the REPL history file for this buffer.
Returns nil when persistence is disabled or no usable directory is
known."
  (cond
   ((eq port-repl-history-file t) nil)
   ((stringp port-repl-history-file)
    (expand-file-name port-repl-history-file))
   (t
    (let ((root (or (and (fboundp 'port-jack-in--detect-project-root)
                         (port-jack-in--detect-project-root))
                    default-directory)))
      (and root (expand-file-name ".port-history" root))))))

(defun port-repl--load-history ()
  "Populate `port-repl-history' from `port-repl--history-file'.
Trims to `port-repl-history-size' and rewrites the file when the
on-disk count exceeds the cap."
  (let ((file port-repl--history-file))
    (when (and file (file-readable-p file))
      (let (entries)
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (while (not (eobp))
            (condition-case _
                (let ((entry (read (current-buffer))))
                  (when (stringp entry) (push entry entries)))
              (error (forward-line 1)))))
        ;; entries is newest-first because we pushed oldest-first reads
        ;; onto the front.
        (let ((trimmed (if (> (length entries) port-repl-history-size)
                           (seq-take entries port-repl-history-size)
                         entries)))
          (setq port-repl-history trimmed)
          (when (and (> (length entries) port-repl-history-size)
                     (file-writable-p file))
            (port-repl--rewrite-history)))))))

(defun port-repl--rewrite-history ()
  "Atomically rewrite the history file with the current trimmed list."
  (let ((file    port-repl--history-file)
        ;; Capture the buffer-local list now -- once we switch to a
        ;; temp buffer the buffer-local binding is gone.
        (entries (reverse port-repl-history)))
    (when (and file (file-writable-p file))
      (with-temp-buffer
        ;; Write oldest-first so that read order matches append order.
        (dolist (entry entries)
          (prin1 entry (current-buffer))
          (insert "\n"))
        (write-region nil nil file nil 'silent)))))

(defun port-repl--append-history (input)
  "Append INPUT to `port-repl--history-file' if persistence is enabled."
  (let ((file port-repl--history-file))
    (when (and file
               (or (file-writable-p file)
                   (file-writable-p (file-name-directory file))))
      (with-temp-buffer
        (prin1 input (current-buffer))
        (insert "\n")
        (write-region nil nil file 'append 'silent)))))

(defun port-repl--connection-handler (conn msg)
  "Forward MSG to CONN's REPL buffer."
  (when-let ((buf (port-client-repl-buffer conn)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (port-repl-handle-message msg)))))

(defun port-repl--insert-prompt ()
  "Insert a fresh prompt at the end of the buffer."
  (let ((inhibit-read-only t)
        (ns (or (and port--connection
                     (port-client-current-ns port--connection))
                "user")))
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (let ((start (point)))
      (insert (format "%s=> " ns))
      (add-text-properties start (point)
                           '(read-only t
                             rear-nonsticky (read-only)
                             front-sticky (read-only)
                             face port-repl-prompt-face
                             field port-repl-prompt))
      (set-marker port-repl-prompt-marker (point)))
    (set-marker port-repl-input-start-marker (point))
    (set-marker-insertion-type port-repl-input-start-marker nil)
    (setq port-repl-prompt-active-p t)))

(defun port-repl-handle-message (msg)
  "Render a single prepl MSG into the current REPL buffer.
MSG is an alist as produced by `port-client--parse-messages'."
  (let ((tag (alist-get :tag msg))
        (val (alist-get :val msg))
        (ns  (alist-get :ns msg)))
    (cond
     ((and (eq tag :ret) (alist-get :exception msg))
      (port-repl--handle-exception val))
     (t
      (port-repl--insert-output
       (pcase tag
         (:ret  (cons (format "%s\n" val) 'port-repl-result-face))
         (:out  (cons val 'port-repl-stdout-face))
         (:err  (cons val 'port-repl-stderr-face))
         (:tap  (cons (format ";; tap> %s\n" val) 'port-repl-tap-face))
         (_     (cons (format ";; %S %s\n" tag val) 'port-repl-tap-face))))))
    (when (and (eq tag :ret) ns)
      (setf (port-client-current-ns port--connection) ns)
      (port-repl--insert-prompt))))

(defun port-repl--handle-exception (val)
  "Handle a `:ret' with `:exception true', whose printed map is VAL.
Inserts a concise one-line summary into the REPL and pops the
stacktrace buffer so the user can drill in."
  (let* ((parsed (port-stacktrace-parse val))
         (summary (port-repl--exception-summary parsed val)))
    (port-repl--insert-output (cons summary 'port-repl-stderr-face))
    (when parsed
      (port-stacktrace-display parsed))))

(defun port-repl--exception-summary (parsed raw)
  "Build a one-line summary string for the exception PARSED (or RAW fallback)."
  (cond
   ((null parsed)
    (format "%s\n" raw))
   (t
    (let* ((via   (alist-get :via parsed))
           (first (car via))
           (type  (and first (alist-get :type first)))
           (msg   (or (and first (alist-get :message first))
                      (alist-get :cause parsed))))
      (format ";; %s%s\n"
              (if type (format "%s: " type) "")
              (or msg "<unknown error>"))))))

(defun port-repl--insert-output (pair)
  "Insert PAIR (a cons of text and face) into the REPL buffer.
If a prompt is currently displayed (`port-repl-prompt-active-p'),
insert above it -- preserving any typed-but-unsent input -- so the
prompt and the user's typing stay at the bottom.  Otherwise (e.g.
between sending a form and receiving its first response message)
just append at point-max."
  (let* ((text (car pair))
         (face (cdr pair))
         (inhibit-read-only t))
    (cond
     (port-repl-prompt-active-p
      (let* ((insert-pos (marker-position port-repl-prompt-marker))
             (saved-input (buffer-substring-no-properties
                           port-repl-input-start-marker (point-max))))
        (delete-region port-repl-input-start-marker (point-max))
        (delete-region (- insert-pos (port-repl--prompt-length)) insert-pos)
        (goto-char (- insert-pos (port-repl--prompt-length)))
        (port-repl--insert-output-text text face)
        (port-repl--insert-prompt)
        (insert saved-input)))
     (t
      (goto-char (point-max))
      (port-repl--insert-output-text text face)
      (set-marker port-repl-prompt-marker (point))
      (set-marker port-repl-input-start-marker (point))))
    (set-window-point (get-buffer-window (current-buffer) 'visible)
                      (point-max))))

(defun port-repl--insert-output-text (text face)
  "Insert TEXT at point with FACE and read-only properties."
  (let ((start (point)))
    (insert text)
    (add-text-properties start (point)
                         `(read-only t
                           rear-nonsticky (read-only)
                           front-sticky (read-only)
                           face ,face))))

(defun port-repl--prompt-length ()
  "Return the character length of the current prompt string."
  (length (format "%s=> "
                  (or (and port--connection
                           (port-client-current-ns port--connection))
                      "user"))))

(defun port-repl-current-input ()
  "Return the text currently in the input area."
  (buffer-substring-no-properties
   port-repl-input-start-marker (point-max)))

(defun port-repl-return ()
  "Send the current input to the prepl, or insert a newline if mid-form."
  (interactive)
  (cond
   ((< (point) port-repl-input-start-marker)
    (goto-char (point-max)))
   (t
    (let ((input (port-repl-current-input)))
      (cond
       ((string-blank-p input)
        (goto-char (point-max))
        (insert "\n"))
       ((not (port-repl--input-complete-p input))
        (goto-char (point-max))
        (insert "\n"))
       (t
        (port-repl-send-input input)))))))

(defun port-repl--input-complete-p (s)
  "Heuristic: does S contain balanced parens/brackets/braces?"
  (let ((depth 0)
        (i 0)
        (len (length s))
        (in-string nil)
        (escape nil))
    (catch 'unbalanced
      (while (< i len)
        (let ((c (aref s i)))
          (cond
           (escape (setq escape nil))
           (in-string
            (cond
             ((eq c ?\\) (setq escape t))
             ((eq c ?\") (setq in-string nil))))
           ((eq c ?\;) ;; line comment
            (while (and (< i len) (not (eq (aref s i) ?\n)))
              (cl-incf i))
            (cl-decf i))
           ((eq c ?\") (setq in-string t))
           ((memq c '(?\( ?\[ ?\{)) (cl-incf depth))
           ((memq c '(?\) ?\] ?\})) (cl-decf depth)
            (when (< depth 0) (throw 'unbalanced nil)))))
        (cl-incf i))
      (and (= depth 0) (not in-string)))))

(defun port-repl-send-input (input)
  "Submit INPUT to the prepl and append it to history."
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (insert "\n")
    (add-text-properties port-repl-input-start-marker (point)
                         '(read-only t
                           rear-nonsticky (read-only)))
    ;; Commit the just-sent text: advance the markers past it and
    ;; mark the prompt as no longer "live", so response messages
    ;; append after the form rather than getting inserted "above
    ;; the prompt".
    (set-marker port-repl-prompt-marker (point))
    (set-marker port-repl-input-start-marker (point))
    (setq port-repl-prompt-active-p nil))
  (port-repl--record-history input)
  (setq port-repl-history-index -1)
  (port-client-send port--connection input))

(defun port-repl--record-history (input)
  "Add INPUT to in-memory history and the persistent file.
Adjacent duplicates are skipped so repeatedly hitting RET on the
same form doesn't fill the ring."
  (unless (or (string-blank-p input)
              (and port-repl-history
                   (equal (car port-repl-history) input)))
    (push input port-repl-history)
    (when (> (length port-repl-history) port-repl-history-size)
      (setq port-repl-history (seq-take port-repl-history
                                        port-repl-history-size)))
    (port-repl--append-history input)))

(defun port-repl-history-previous ()
  "Cycle back through input history."
  (interactive)
  (when port-repl-history
    (cl-incf port-repl-history-index)
    (when (>= port-repl-history-index (length port-repl-history))
      (setq port-repl-history-index (1- (length port-repl-history))))
    (port-repl--replace-input
     (nth port-repl-history-index port-repl-history))))

(defun port-repl-history-next ()
  "Cycle forward through input history."
  (interactive)
  (cond
   ((<= port-repl-history-index 0)
    (setq port-repl-history-index -1)
    (port-repl--replace-input ""))
   (t
    (cl-decf port-repl-history-index)
    (port-repl--replace-input
     (nth port-repl-history-index port-repl-history)))))

(defun port-repl--replace-input (text)
  "Replace the input area with TEXT."
  (let ((inhibit-read-only t))
    (delete-region port-repl-input-start-marker (point-max))
    (goto-char (point-max))
    (insert text)))

(defun port-repl-clear-buffer ()
  "Clear the REPL buffer (output only)."
  (interactive)
  (let ((inhibit-read-only t)
        (input (port-repl-current-input)))
    (erase-buffer)
    (port-repl--insert-prompt)
    (insert input)))

(defun port-repl-interrupt ()
  "Placeholder for interrupting the current evaluation.
prepl has no direct interrupt op; this is a stub for future work."
  (interactive)
  (message "Port: interrupt is not yet supported on prepl"))

(defun port-repl--active-buffer ()
  "Return the REPL buffer of the current session, or nil."
  (when port-default-session
    (let ((buf (port-session-repl-buffer port-default-session)))
      (and (buffer-live-p buf) buf))))

(defun port-repl-emit-comment (text)
  "Emit TEXT as a comment line in the active REPL buffer."
  (when-let ((buf (port-repl--active-buffer)))
    (with-current-buffer buf
      (port-repl--insert-output
       (cons (format ";; %s\n" text) 'port-repl-tap-face)))))

(defun port-repl-emit-text (text &optional face)
  "Emit raw TEXT into the active REPL buffer.
Optional FACE defaults to `port-repl-result-face'."
  (when-let ((buf (port-repl--active-buffer)))
    (with-current-buffer buf
      (port-repl--insert-output
       (cons (if (string-suffix-p "\n" text) text (concat text "\n"))
             (or face 'port-repl-result-face))))))

(provide 'port-repl)

;;; port-repl.el ends here

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
(require 'port-client)

(defvar-local port--connection nil
  "The `port-client' associated with this REPL buffer.")

(defvar-local port-repl-input-start-marker nil
  "Marker at the start of the editable input area.")

(defvar-local port-repl-prompt-marker nil
  "Marker just past the most recently inserted prompt.")

(defvar-local port-repl-history nil
  "Ring of previously sent inputs (most recent first).")

(defvar-local port-repl-history-index -1
  "Current position in `port-repl-history' while browsing.")

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
  (when (fboundp 'clojure-mode-syntax-table)
    (set-syntax-table (clojure-mode-syntax-table))))

(defun port-repl-create-buffer (conn)
  "Create and return a fresh REPL buffer for CONN."
  (let* ((host (port-client-host conn))
         (port (port-client-port conn))
         (name (format "*port-repl: %s:%d*" host port))
         (buf  (get-buffer-create name)))
    (with-current-buffer buf
      (port-repl-mode)
      (setq port--connection conn)
      (setq port-repl-input-start-marker (make-marker))
      (setq port-repl-prompt-marker (make-marker))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format ";; Port %s connected to %s:%d\n"
                        (or (and (boundp 'port-version) port-version) "")
                        host port)))
      (port-repl--insert-prompt))
    (setf (port-client-handler conn) #'port-repl--connection-handler)
    (setf (port-client-repl-buffer conn) buf)
    buf))

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
    (set-marker-insertion-type port-repl-input-start-marker nil)))

(defun port-repl-handle-message (msg)
  "Render a single prepl MSG into the current REPL buffer.
MSG is an alist as produced by `port-client--parse-messages'."
  (let ((tag (alist-get :tag msg))
        (val (alist-get :val msg))
        (ns  (alist-get :ns msg)))
    (port-repl--insert-output
     (pcase tag
       (:ret  (cons (port-repl--format-ret val msg) 'port-repl-result-face))
       (:out  (cons val 'port-repl-stdout-face))
       (:err  (cons val 'port-repl-stderr-face))
       (:tap  (cons (format ";; tap> %s\n" val) 'port-repl-tap-face))
       (_     (cons (format ";; %S %s\n" tag val) 'port-repl-tap-face))))
    (when (and (eq tag :ret) ns)
      (setf (port-client-current-ns port--connection) ns)
      (port-repl--insert-prompt))))

(defun port-repl--format-ret (val msg)
  "Format the printed return VAL from MSG, with trailing newline."
  (if (alist-get :exception msg)
      (format "%s\n" val)
    (format "%s\n" val)))

(defun port-repl--insert-output (text+face)
  "Insert TEXT+FACE (a (TEXT . FACE) pair) into the buffer above the prompt."
  (let* ((text (car text+face))
         (face (cdr text+face))
         (inhibit-read-only t)
         (insert-pos (marker-position port-repl-prompt-marker))
         (input-active (< insert-pos (point-max)))
         (saved-input (when input-active
                        (buffer-substring-no-properties
                         port-repl-input-start-marker (point-max)))))
    (when input-active
      (delete-region port-repl-input-start-marker (point-max))
      (delete-region (- insert-pos (port-repl--prompt-length)) insert-pos))
    (goto-char (if input-active
                   (- insert-pos (port-repl--prompt-length))
                 insert-pos))
    (let ((start (point)))
      (insert text)
      (add-text-properties start (point)
                           `(read-only t
                             rear-nonsticky (read-only)
                             front-sticky (read-only)
                             face ,face)))
    (when input-active
      (port-repl--insert-prompt)
      (insert saved-input))
    (set-window-point (get-buffer-window (current-buffer) 'visible)
                      (point-max))))

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
                           rear-nonsticky (read-only))))
  (push input port-repl-history)
  (setq port-repl-history-index -1)
  (port-client-send port--connection input))

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

(defun port-repl-emit-comment (text)
  "Emit TEXT as a comment line in the REPL (for command echoes)."
  (when (and port--connection (port-client-repl-buffer port--connection))
    (with-current-buffer (port-client-repl-buffer port--connection)
      (port-repl--insert-output
       (cons (format ";; %s\n" text) 'port-repl-tap-face)))))

(provide 'port-repl)

;;; port-repl.el ends here

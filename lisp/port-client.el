;;; port-client.el --- prepl socket client -*- lexical-binding: t -*-

;; Copyright © 2026 Bozhidar Batsov and Port contributors

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A small TCP client for Clojure's prepl.  Sends Clojure forms as text
;; and parses the streaming EDN response messages, routing them via a
;; per-connection handler.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(cl-defstruct (port-client
               (:constructor port-client--make)
               (:copier nil))
  "A live prepl connection."
  host
  port
  process
  buffer            ; private parse buffer
  pending           ; not-yet-parsed bytes
  repl-buffer       ; the REPL display buffer for this connection
  current-ns        ; tracked from :ret messages
  handler)          ; function called with each parsed message map

(defun port-client-connect (host port)
  "Open a prepl connection to HOST:PORT.
Returns the `port-client' struct."
  (let* ((proc-buf (generate-new-buffer (format " *port-client-%s:%d*" host port)))
         (proc (make-network-process
                :name (format "port-%s:%d" host port)
                :host host
                :service port
                :coding 'utf-8-unix
                :nowait nil
                :buffer proc-buf
                :noquery t)))
    (let ((conn (port-client--make
                 :host host
                 :port port
                 :process proc
                 :buffer proc-buf
                 :pending ""
                 :current-ns "user"
                 :handler #'ignore)))
      (process-put proc 'port-connection conn)
      (set-process-filter proc #'port-client--filter)
      (set-process-sentinel proc #'port-client--sentinel)
      conn)))

(defun port-client-disconnect (conn)
  "Close CONN."
  (when (process-live-p (port-client-process conn))
    (delete-process (port-client-process conn)))
  (when (buffer-live-p (port-client-buffer conn))
    (kill-buffer (port-client-buffer conn))))

(defun port-client-send (conn form-string)
  "Send FORM-STRING (a Clojure form as text) to CONN.
The string need not be terminated by a newline; one is appended."
  (let ((proc (port-client-process conn)))
    (unless (process-live-p proc)
      (user-error "Port: connection is not live"))
    (process-send-string proc (concat form-string "\n"))))

(defun port-client--sentinel (proc event)
  "Handle PROC EVENT for a prepl connection."
  (let ((conn (process-get proc 'port-connection)))
    (when (and conn (memq (process-status proc) '(closed exit failed signal)))
      (when-let ((repl (port-client-repl-buffer conn)))
        (when (buffer-live-p repl)
          (with-current-buffer repl
            (let ((inhibit-read-only t))
              (goto-char (point-max))
              (insert (format "\n;; Connection %s\n" (string-trim event))))))))))

(defun port-client--filter (proc chunk)
  "Process filter for prepl PROC receiving CHUNK."
  (let* ((conn (process-get proc 'port-connection))
         (text (concat (port-client-pending conn) chunk)))
    (let ((parsed (port-client--parse-messages text)))
      (setf (port-client-pending conn) (cdr parsed))
      (dolist (msg (car parsed))
        (when-let ((ns (alist-get :ns msg)))
          (setf (port-client-current-ns conn) ns))
        (funcall (port-client-handler conn) conn msg)))))


;;; Message parsing
;;
;; prepl emits one EDN map per message, separated by newlines via `prn'.
;; We need a small EDN reader that handles the subset used: maps with
;; keyword keys, keyword values (for :tag), strings, integers, booleans,
;; nil.  Strings may contain escaped newlines and quotes.

(defun port-client--parse-messages (text)
  "Parse zero or more messages from TEXT.
Return (MESSAGES . LEFTOVER) where MESSAGES is a list of alists and
LEFTOVER is the unparsed tail."
  (let ((pos 0)
        (len (length text))
        (msgs '()))
    (catch 'done
      (while (< pos len)
        ;; Skip whitespace between messages.
        (while (and (< pos len)
                    (memq (aref text pos) '(?\s ?\t ?\n ?\r ?,)))
          (cl-incf pos))
        (when (>= pos len) (throw 'done nil))
        (condition-case _
            (let ((res (port-client--read text pos)))
              (push (car res) msgs)
              (setq pos (cdr res)))
          ;; Incomplete form -- bail out and keep the rest as leftover.
          (port-edn-incomplete (throw 'done nil))
          ;; Genuinely malformed -- drop one char to avoid infinite loop.
          (error (cl-incf pos)))))
    (cons (nreverse msgs) (substring text pos))))

(define-error 'port-edn-incomplete "Incomplete EDN form")

(defun port-client--read (s pos)
  "Read one EDN value from S at POS, returning (VALUE . NEW-POS)."
  (setq pos (port-client--skip-ws s pos))
  (when (>= pos (length s))
    (signal 'port-edn-incomplete nil))
  (let ((c (aref s pos)))
    (cond
     ((eq c ?\{) (port-client--read-map s (1+ pos)))
     ((eq c ?\[) (port-client--read-seq s (1+ pos) ?\]))
     ((eq c ?\() (port-client--read-seq s (1+ pos) ?\)))
     ((eq c ?\") (port-client--read-string s (1+ pos)))
     ((eq c ?\:) (port-client--read-keyword s (1+ pos)))
     ((or (and (>= c ?0) (<= c ?9))
          (and (eq c ?-)
               (< (1+ pos) (length s))
               (let ((d (aref s (1+ pos))))
                 (and (>= d ?0) (<= d ?9)))))
      (port-client--read-number s pos))
     ;; nil / true / false / symbol-ish.  We only need t/f/nil for prepl.
     (t (port-client--read-atom s pos)))))

(defun port-client--skip-ws (s pos)
  "Advance past whitespace and commas in S starting at POS."
  (let ((len (length s)))
    (while (and (< pos len)
                (memq (aref s pos) '(?\s ?\t ?\n ?\r ?,)))
      (cl-incf pos))
    pos))

(defun port-client--read-map (s pos)
  "Read a map body from S at POS (just past `{').
Return ((KEY . VAL) ...) as an alist, plus new position."
  (let ((entries '()))
    (catch 'done
      (while t
        (setq pos (port-client--skip-ws s pos))
        (when (>= pos (length s))
          (signal 'port-edn-incomplete nil))
        (when (eq (aref s pos) ?\})
          (throw 'done (cons (nreverse entries) (1+ pos))))
        (let* ((k (port-client--read s pos))
               (kv (car k))
               (kp (cdr k))
               (v (port-client--read s kp)))
          (push (cons kv (car v)) entries)
          (setq pos (cdr v)))))))

(defun port-client--read-seq (s pos close)
  "Read a vector or list body from S at POS until CLOSE (`]' or `)').
Return (LIST . NEW-POS) where LIST is an Elisp list of the elements."
  (let ((items '()))
    (catch 'done
      (while t
        (setq pos (port-client--skip-ws s pos))
        (when (>= pos (length s))
          (signal 'port-edn-incomplete nil))
        (when (eq (aref s pos) close)
          (throw 'done (cons (nreverse items) (1+ pos))))
        (let ((v (port-client--read s pos)))
          (push (car v) items)
          (setq pos (cdr v)))))))

(defun port-client--read-string (s pos)
  "Read a string from S at POS (just past opening quote).
Accumulates chars into a list and `apply'es `string' at the end
so an N-byte string isn't quadratic in N."
  (let ((chars '())
        (len (length s))
        (done nil))
    (while (not done)
      (when (>= pos len) (signal 'port-edn-incomplete nil))
      (let ((c (aref s pos)))
        (cond
         ((eq c ?\")
          (cl-incf pos)
          (setq done t))
         ((eq c ?\\)
          (when (>= (1+ pos) len) (signal 'port-edn-incomplete nil))
          (let ((esc (aref s (1+ pos))))
            (cond
             ((eq esc ?u)
              ;; \uXXXX -- the 4 hex digits must already be present;
              ;; otherwise the chunk is incomplete.
              (when (< len (+ pos 6)) (signal 'port-edn-incomplete nil))
              (push (string-to-number (substring s (+ pos 2) (+ pos 6)) 16)
                    chars)
              (cl-incf pos 6))
             (t
              (push (pcase esc
                      (?n  ?\n)
                      (?t  ?\t)
                      (?r  ?\r)
                      (?\\ ?\\)
                      (?\" ?\")
                      (?b  ?\b)
                      (?f  ?\f)
                      (?/  ?/)
                      (_   esc))
                    chars)
              (cl-incf pos 2)))))
         (t
          (push c chars)
          (cl-incf pos)))))
    (cons (apply #'string (nreverse chars)) pos)))

(defun port-client--read-keyword (s pos)
  "Read a keyword from S at POS (just past colon).
Returns the value as an Elisp keyword like :tag."
  (let ((start pos)
        (len (length s)))
    (while (and (< pos len)
                (port-client--keyword-char-p (aref s pos)))
      (cl-incf pos))
    (when (= start pos) (signal 'port-edn-incomplete nil))
    (cons (intern (concat ":" (substring s start pos))) pos)))

(defun port-client--keyword-char-p (c)
  "Return non-nil if C is valid in an EDN keyword/symbol body."
  (or (and (>= c ?a) (<= c ?z))
      (and (>= c ?A) (<= c ?Z))
      (and (>= c ?0) (<= c ?9))
      (memq c '(?- ?_ ?. ?+ ?* ?! ?? ?/ ?$ ?% ?& ?= ?< ?> ?:))))

(defun port-client--read-number (s pos)
  "Read a number from S at POS."
  (let ((start pos)
        (len (length s)))
    (when (eq (aref s pos) ?-) (cl-incf pos))
    (while (and (< pos len)
                (let ((c (aref s pos)))
                  (or (and (>= c ?0) (<= c ?9))
                      (memq c '(?. ?e ?E ?+ ?- ?N ?M)))))
      (cl-incf pos))
    (cons (string-to-number (substring s start pos)) pos)))

(defun port-client--read-atom (s pos)
  "Read a bare atom (true/false/nil/symbol) from S at POS."
  (let ((start pos)
        (len (length s)))
    (while (and (< pos len)
                (port-client--keyword-char-p (aref s pos)))
      (cl-incf pos))
    (let ((tok (substring s start pos)))
      (cons (pcase tok
              ("true" t)
              ("false" :false)
              ("nil"  nil)
              (_ (intern tok)))
            pos))))

(provide 'port-client)

;;; port-client.el ends here

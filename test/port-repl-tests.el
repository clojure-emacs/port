;;; port-repl-tests.el --- Tests for port-repl -*- lexical-binding: t -*-

;;; Commentary:

;; Buffer-display tests for the REPL.  These don't talk to a real
;; prepl: we drive `port-repl-handle-message' directly with synthetic
;; messages and inspect the resulting buffer text.

;;; Code:

(require 'buttercup)
(require 'cl-lib)
(require 'port-client)
(require 'port-session)
(require 'port-repl)

(defun port-repl-tests--fresh-buffer ()
  "Create a fresh REPL buffer with a stub session and connection."
  (let* ((conn    (port-client--make :host "h" :port 1 :process nil
                                     :buffer nil :pending ""
                                     :current-ns "user" :handler #'ignore))
         (session (port-session--make :host "h" :port 1
                                      :user-conn conn :tool-conn nil))
         (buf     (port-repl-create-buffer session)))
    buf))

(defun port-repl-tests--visible-text (buf)
  "Return BUF's text as plain characters."
  (with-current-buffer buf
    (buffer-substring-no-properties (point-min) (point-max))))

(defun port-repl-tests--with-history-file (thunk)
  "Run THUNK with a temp history file rebound for the current buffer.
THUNK is called with the file path as its single argument; the
file is removed afterwards."
  (let* ((file (make-temp-file "port-history-")))
    (unwind-protect
        (progn
          (setq-local port-repl--history-file file
                      port-repl-history nil
                      port-repl-history-index -1)
          (funcall thunk file))
      (when (file-exists-p file)
        (delete-file file)))))

(describe "rendering prepl messages"

  (it "places :ret after the form, with a fresh prompt below"
    (let ((buf (port-repl-tests--fresh-buffer)))
      (unwind-protect
          (with-current-buffer buf
            ;; Simulate the user typing "(+ 1 2)" at the prompt.
            (goto-char (point-max))
            (insert "(+ 1 2)")
            ;; Manually freeze the input the same way
            ;; `port-repl-send-input' does, but without sending.
            (let ((inhibit-read-only t))
              (goto-char (point-max))
              (insert "\n")
              (add-text-properties port-repl-input-start-marker (point)
                                   '(read-only t rear-nonsticky (read-only)))
              (set-marker port-repl-prompt-marker (point))
              (set-marker port-repl-input-start-marker (point))
              (setq port-repl-prompt-active-p nil))
            (port-repl-handle-message
             '((:tag . :out) (:val . "hi\n")))
            (port-repl-handle-message
             '((:tag . :ret) (:val . "3") (:ns . "user")))
            (let ((text (port-repl-tests--visible-text buf)))
              (expect text :to-match "(\\+ 1 2)\nhi\n3\nuser=> ")
              ;; Sanity: the result should NOT precede the form.
              (expect text :not :to-match "3\n.*(\\+ 1 2)")))
        (kill-buffer buf))))

  (it "preserves typed input when output arrives mid-typing"
    (let ((buf (port-repl-tests--fresh-buffer)))
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-max))
            (insert "abc")
            (port-repl-handle-message
             '((:tag . :tap) (:val . "ping")))
            (let ((text (port-repl-tests--visible-text buf)))
              (expect text :to-match ";; tap> ping\nuser=> abc")))
        (kill-buffer buf))))

  (it "renders an exception inline as a one-line summary and pops the buffer"
    (let ((buf (port-repl-tests--fresh-buffer))
          (port-stacktrace-auto-open nil))
      (unwind-protect
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (goto-char (point-max))
              (set-marker port-repl-prompt-marker (point))
              (set-marker port-repl-input-start-marker (point))
              (setq port-repl-prompt-active-p nil))
            (port-repl-handle-message
             `((:tag . :ret)
               (:val . ,(concat "{:via [{:type clojure.lang.ExceptionInfo"
                                " :message \"boom\" :data {:foo 1}}]"
                                " :trace [[user$f invokeStatic \"x.clj\" 1]]"
                                " :cause \"boom\"}"))
               (:ns . "user")
               (:exception . t)))
            (let ((text (port-repl-tests--visible-text buf)))
              (expect text :to-match "ExceptionInfo: boom")
              ;; The raw printed map should not have been dumped.
              (expect text :not :to-match ":trace \\[")
              ;; A fresh prompt should follow.
              (expect text :to-match "user=> $"))
            (let ((stbuf (get-buffer port-stacktrace-buffer-name)))
              (expect stbuf :to-be-truthy)
              (with-current-buffer stbuf
                (let ((stext (buffer-substring-no-properties
                              (point-min) (point-max))))
                  (expect stext :to-match "ExceptionInfo")
                  (expect stext :to-match "x.clj:1")))))
        (kill-buffer buf)
        (when (get-buffer port-stacktrace-buffer-name)
          (kill-buffer port-stacktrace-buffer-name))))))

(describe "input history"

  (it "appends to file and skips blanks/adjacent duplicates"
    (let ((buf (port-repl-tests--fresh-buffer)))
      (unwind-protect
          (with-current-buffer buf
            (port-repl-tests--with-history-file
             (lambda (_file)
               ;; Three sends, but two are duplicates and one is blank.
               (port-repl--record-history "(+ 1 1)")
               (port-repl--record-history "(+ 1 1)")  ; duplicate, dropped
               (port-repl--record-history "(* 2 3)")
               (port-repl--record-history "")        ; blank, dropped
               (expect port-repl-history
                       :to-equal '("(* 2 3)" "(+ 1 1)"))
               ;; Reload from disk into a fresh buffer state.
               (setq port-repl-history nil)
               (port-repl--load-history)
               (expect port-repl-history
                       :to-equal '("(* 2 3)" "(+ 1 1)")))))
        (kill-buffer buf))))

  (it "trims to `port-repl-history-size' and rewrites the oversized file"
    (let ((buf (port-repl-tests--fresh-buffer))
          (port-repl-history-size 3))
      (unwind-protect
          (with-current-buffer buf
            (port-repl-tests--with-history-file
             (lambda (file)
               (dolist (i '(1 2 3 4 5 6 7))
                 (port-repl--record-history (format "(form %d)" i)))
               (expect (length port-repl-history) :to-equal 3)
               (expect (car port-repl-history) :to-equal "(form 7)")
               ;; Load also trims the oversized file.
               (setq port-repl-history nil)
               (port-repl--load-history)
               (expect (length port-repl-history) :to-equal 3)
               ;; And the file on disk is now exactly 3 lines.
               (with-temp-buffer
                 (insert-file-contents file)
                 (expect (count-lines (point-min) (point-max))
                         :to-equal 3)))))
        (kill-buffer buf))))

  (it "does not resolve a path when persistence is disabled (t)"
    (let ((port-repl-history-file t))
      (with-temp-buffer
        (port-repl-mode)
        (expect (port-repl--resolve-history-file) :to-be nil))))

  (it "honors an explicit `port-repl-history-file' path"
    (let* ((path (make-temp-file "port-history-explicit-"))
           (port-repl-history-file path))
      (unwind-protect
          (with-temp-buffer
            (port-repl-mode)
            (expect (port-repl--resolve-history-file) :to-equal path))
        (delete-file path)))))

(describe "REPL buffer lifecycle"

  (it "wires `port-completion-at-point' into the buffer"
    (let ((buf (port-repl-tests--fresh-buffer)))
      (unwind-protect
          (with-current-buffer buf
            (expect (memq #'port-completion-at-point
                          completion-at-point-functions)
                    :to-be-truthy))
        (kill-buffer buf))))

  (it "shuts down the session when the buffer is killed"
    (let* ((called nil)
           (buf (port-repl-tests--fresh-buffer)))
      (cl-letf (((symbol-function 'port-session-shutdown)
                 (lambda (s) (setq called s))))
        (kill-buffer buf))
      (expect called :to-be-truthy))))

(provide 'port-repl-tests)

;;; port-repl-tests.el ends here

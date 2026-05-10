;;; port-repl-tests.el --- Tests for port-repl -*- lexical-binding: t -*-

;;; Commentary:

;; Buffer-display tests for the REPL.  These don't talk to a real
;; prepl: we drive `port-repl-handle-message' directly with synthetic
;; messages and inspect the resulting buffer text.

;;; Code:

(require 'ert)
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
  "Return BUF's text with ASCII-printable + newlines kept verbatim."
  (with-current-buffer buf
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest port-repl-test-result-renders-after-form ()
  "After sending a form, the :ret value should appear after it,
not above the prompt."
  (let ((buf (port-repl-tests--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          ;; Simulate the user typing "(+ 1 2)" at the prompt.
          (goto-char (point-max))
          (insert "(+ 1 2)")
          ;; Manually freeze the input the same way `port-repl-send-input'
          ;; does, but without actually sending to a process.
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert "\n")
            (add-text-properties port-repl-input-start-marker (point)
                                 '(read-only t rear-nonsticky (read-only)))
            (set-marker port-repl-prompt-marker (point))
            (set-marker port-repl-input-start-marker (point))
            (setq port-repl-prompt-active-p nil))
          ;; The prepl response.
          (port-repl-handle-message
           '((:tag . :out) (:val . "hi\n")))
          (port-repl-handle-message
           '((:tag . :ret) (:val . "3") (:ns . "user")))
          (let ((text (port-repl-tests--visible-text buf)))
            (should (string-match-p "(\\+ 1 2)\nhi\n3\nuser=> " text))
            ;; Sanity: the result should NOT precede the form.
            (should-not (string-match-p "3\n.*(\\+ 1 2)" text))))
      (kill-buffer buf))))

(ert-deftest port-repl-test-async-output-preserves-typing ()
  "Output that arrives while the user is mid-typing should appear
above the prompt and the typed input should be preserved."
  (let ((buf (port-repl-tests--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "abc") ;; user is typing, hasn't hit RET
          (port-repl-handle-message
           '((:tag . :tap) (:val . "ping")))
          (let ((text (port-repl-tests--visible-text buf)))
            (should (string-match-p ";; tap> ping\nuser=> abc" text))))
      (kill-buffer buf))))

(ert-deftest port-repl-test-exception-renders-summary-and-pops-buffer ()
  "An exception :ret should emit a one-line summary inline and
populate the *port-stacktrace* buffer."
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
            (should (string-match-p "ExceptionInfo: boom" text))
            ;; The raw printed map should not have been dumped.
            (should-not (string-match-p ":trace \\[" text))
            ;; A fresh prompt should follow.
            (should (string-match-p "user=> $" text)))
          (let ((stbuf (get-buffer port-stacktrace-buffer-name)))
            (should stbuf)
            (with-current-buffer stbuf
              (let ((stext (buffer-substring-no-properties
                            (point-min) (point-max))))
                (should (string-match-p "ExceptionInfo" stext))
                (should (string-match-p "x.clj:1" stext))))))
      (kill-buffer buf)
      (when (get-buffer port-stacktrace-buffer-name)
        (kill-buffer port-stacktrace-buffer-name)))))

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

(ert-deftest port-repl-test-history-append-and-load ()
  (let ((buf (port-repl-tests--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (port-repl-tests--with-history-file
           (lambda (_file)
             ;; Three sends, but two are duplicates.
             (port-repl--record-history "(+ 1 1)")
             (port-repl--record-history "(+ 1 1)")  ; duplicate, dropped
             (port-repl--record-history "(* 2 3)")
             (port-repl--record-history "")        ; blank, dropped
             ;; In-memory history is most-recent-first, no adj. dups.
             (should (equal '("(* 2 3)" "(+ 1 1)") port-repl-history))
             ;; Reload from disk into a fresh buffer state.
             (setq port-repl-history nil)
             (port-repl--load-history)
             (should (equal '("(* 2 3)" "(+ 1 1)") port-repl-history)))))
      (kill-buffer buf))))

(ert-deftest port-repl-test-history-load-trims-and-rewrites ()
  (let ((buf (port-repl-tests--fresh-buffer))
        (port-repl-history-size 3))
    (unwind-protect
        (with-current-buffer buf
          (port-repl-tests--with-history-file
           (lambda (file)
             (dolist (i '(1 2 3 4 5 6 7))
               (port-repl--record-history (format "(form %d)" i)))
             ;; In-memory list trimmed to 3 most-recent.
             (should (= 3 (length port-repl-history)))
             (should (equal "(form 7)" (car port-repl-history)))
             ;; Load also trims the oversized file.
             (setq port-repl-history nil)
             (port-repl--load-history)
             (should (= 3 (length port-repl-history)))
             ;; And the file on disk is now exactly 3 lines.
             (with-temp-buffer
               (insert-file-contents file)
               (should (= 3 (count-lines (point-min) (point-max))))))))
      (kill-buffer buf))))

(ert-deftest port-repl-test-history-disabled ()
  "When `port-repl-history-file' is t, no file is resolved."
  (let ((port-repl-history-file t))
    (with-temp-buffer
      (port-repl-mode)
      (should (null (port-repl--resolve-history-file))))))

(ert-deftest port-repl-test-history-uses-explicit-file ()
  (let* ((path (make-temp-file "port-history-explicit-"))
         (port-repl-history-file path))
    (unwind-protect
        (with-temp-buffer
          (port-repl-mode)
          (should (equal path (port-repl--resolve-history-file))))
      (delete-file path))))

(ert-deftest port-repl-test-kill-buffer-shuts-down-session ()
  "Killing the REPL buffer should run `port-session-shutdown'."
  (let* ((called nil)
         (buf (port-repl-tests--fresh-buffer)))
    (cl-letf (((symbol-function 'port-session-shutdown)
               (lambda (s) (setq called s))))
      (kill-buffer buf))
    (should called)))

(provide 'port-repl-tests)

;;; port-repl-tests.el ends here

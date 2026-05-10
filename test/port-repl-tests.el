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

(provide 'port-repl-tests)

;;; port-repl-tests.el ends here

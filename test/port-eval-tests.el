;;; port-eval-tests.el --- Tests for port-eval -*- lexical-binding: t -*-

;;; Commentary:

;; Tests for the eval-display dispatch and rendering helpers.  We
;; don't talk to a real prepl: we synthesize result alists and
;; capture what `message' would print and what gets emitted into a
;; fixture REPL buffer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'port-client)
(require 'port-session)
(require 'port-repl)
(require 'port-tooling)
(require 'port-eval)

(defun port-eval-tests--with-message (thunk)
  "Run THUNK; return the last formatted message it produced."
  (let (captured)
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq captured (apply #'format fmt args)))))
      (funcall thunk))
    captured))

(defun port-eval-tests--make-session ()
  "Create a session with a stub user-conn (no real process)."
  (let ((conn (port-client--make :host "h" :port 1 :process nil
                                 :buffer nil :pending ""
                                 :current-ns "user" :handler #'ignore)))
    (port-session--make :host "h" :port 1
                        :user-conn conn :tool-conn conn)))

(ert-deftest port-eval-test-display-minibuffer-shows-value ()
  (let* ((port-eval-display 'minibuffer)
         (session (port-eval-tests--make-session))
         (port-default-session session)
         (msg (port-eval-tests--with-message
               (lambda ()
                 (port-eval--display-result
                  '((:tag . :ok) (:val . "3")
                    (:out . "") (:err . "") (:ns . "user")))))))
    (should (equal "=> 3" msg))))

(ert-deftest port-eval-test-display-error-uses-ex-message ()
  (let* ((port-eval-display 'minibuffer)
         (session (port-eval-tests--make-session))
         (port-default-session session)
         (msg (port-eval-tests--with-message
               (lambda ()
                 (port-eval--display-result
                  '((:tag . :err)
                    (:ex-message . "Divide by zero")
                    (:ex . "{:cause \"Divide by zero\" ...}")
                    (:out . "") (:err . "")))))))
    (should (equal "Divide by zero" msg))))

(ert-deftest port-eval-test-display-error-falls-back-to-ex ()
  "When :ex-message is missing, fall back to the printed Throwable->map."
  (let* ((port-eval-display 'minibuffer)
         (session (port-eval-tests--make-session))
         (port-default-session session)
         (msg (port-eval-tests--with-message
               (lambda ()
                 (port-eval--display-result
                  '((:tag . :err)
                    (:ex . "boom") (:out . "") (:err . "")))))))
    (should (equal "boom" msg))))

(ert-deftest port-eval-test-display-both-echoes-result-to-repl ()
  (let* ((session (port-eval-tests--make-session))
         (port-default-session session)
         (port-eval-display 'both)
         (buf (port-repl-create-buffer session)))
    (unwind-protect
        (progn
          (port-eval-tests--with-message
           (lambda ()
             (port-eval--display-result
              '((:tag . :ok) (:val . "42")
                (:out . "") (:err . "") (:ns . "user")))))
          (with-current-buffer buf
            (should (string-match-p "42\nuser=> "
                                    (buffer-substring-no-properties
                                     (point-min) (point-max))))))
      (kill-buffer buf))))

(ert-deftest port-eval-test-display-out-always-emitted-to-repl ()
  "Captured stdout should land in the REPL even in `minibuffer' mode."
  (let* ((session (port-eval-tests--make-session))
         (port-default-session session)
         (port-eval-display 'minibuffer)
         (buf (port-repl-create-buffer session)))
    (unwind-protect
        (progn
          (port-eval-tests--with-message
           (lambda ()
             (port-eval--display-result
              '((:tag . :ok) (:val . "nil")
                (:out . "side-effect\n") (:err . "")
                (:ns . "user")))))
          (with-current-buffer buf
            (should (string-match-p "side-effect\n"
                                    (buffer-substring-no-properties
                                     (point-min) (point-max))))))
      (kill-buffer buf))))

(ert-deftest port-eval-test-current-ns-prefers-buffer-ns ()
  "Honor `clojure-find-ns' when it returns a value."
  (let ((session (port-eval-tests--make-session)))
    (cl-letf (((symbol-function 'clojure-find-ns) (lambda () "my.ns")))
      (should (equal "my.ns" (port-eval--current-ns session))))))

(ert-deftest port-eval-test-current-ns-falls-back-to-regex ()
  "Without `clojure-find-ns' the regex-based extractor takes over."
  (let* ((session (port-eval-tests--make-session)))
    (with-temp-buffer
      (insert "(ns my.regex.ns)\n(defn foo [] :hi)\n")
      (cl-letf (((symbol-function 'clojure-find-ns) (lambda () nil)))
        (should (equal "my.regex.ns" (port-eval--current-ns session)))))))

(ert-deftest port-eval-test-current-ns-falls-back-to-user-conn ()
  "Final fallback is the user socket's tracked ns."
  (let* ((session (port-eval-tests--make-session)))
    (setf (port-client-current-ns (port-session-user-conn session)) "lib.foo")
    (with-temp-buffer
      ;; No ns form in the buffer, no clojure-find-ns: fall through.
      (cl-letf (((symbol-function 'clojure-find-ns) (lambda () nil)))
        (should (equal "lib.foo" (port-eval--current-ns session)))))))

(ert-deftest port-eval-test-current-buffer-ns-recognises-ns-form ()
  (with-temp-buffer
    (insert ";; preamble\n(ns app.core\n  (:require [clojure.string :as str]))\n")
    (should (equal "app.core" (port-current-buffer-ns)))))

(ert-deftest port-eval-test-current-buffer-ns-returns-nil-without-form ()
  (with-temp-buffer
    (insert "(defn standalone [])\n")
    (should (null (port-current-buffer-ns)))))

(ert-deftest port-tooling-test-user-eval-form-construction ()
  "Verify the wire form sent for a `port-tooling-user-eval' call."
  (let* ((session (port-eval-tests--make-session))
         (port-print-length 50)
         (port-print-level 5)
         sent)
    (cl-letf (((symbol-function 'port-client-send)
               (lambda (_conn s) (setq sent s))))
      (port-tooling-user-eval session "my.ns" "(+ 1 2)" #'ignore))
    (should (string-match-p "(port\\.tooling/-user-eval [0-9]+ (quote my\\.ns)"
                            sent))
    ;; The code is sent as a properly quoted Clojure string literal.
    (should (string-match-p (regexp-quote "\"(+ 1 2)\"") sent))
    ;; The print-length and print-level integers follow.
    (should (string-match-p "\" 50 5)$" sent))))

(ert-deftest port-eval-test-summary-line-passes-single-line-through ()
  (should (equal "42" (port-eval--summary-line "42")))
  (should (equal "{:a 1, :b 2}" (port-eval--summary-line "{:a 1, :b 2}")))
  (should (equal nil (port-eval--summary-line nil))))

(ert-deftest port-eval-test-summary-line-truncates-multiline ()
  (let ((s (port-eval--summary-line "{:a 1\n :b 2\n :c 3}")))
    (should (string-prefix-p "{:a 1" s))
    (should (string-suffix-p "…" s))
    (should-not (string-match-p "\n" s))))

(ert-deftest port-eval-test-display-minibuffer-truncates-multiline-value ()
  (let* ((port-eval-display 'minibuffer)
         (session (port-eval-tests--make-session))
         (port-default-session session)
         (msg (port-eval-tests--with-message
               (lambda ()
                 (port-eval--display-result
                  '((:tag . :ok) (:val . "{:a 1\n :b 2}")
                    (:out . "") (:err . "") (:ns . "user")))))))
    (should (string-prefix-p "=> {:a 1" msg))
    (should (string-suffix-p "…" msg))
    (should-not (string-match-p "\n" msg))))

(ert-deftest port-tooling-test-user-eval-passes-nil-print-caps ()
  "When `port-print-length' / `port-print-level' are nil, send `nil'."
  (let* ((session (port-eval-tests--make-session))
         (port-print-length nil)
         (port-print-level nil)
         sent)
    (cl-letf (((symbol-function 'port-client-send)
               (lambda (_conn s) (setq sent s))))
      (port-tooling-user-eval session "user" "x" #'ignore))
    (should (string-match-p "\" nil nil)$" sent))))

(ert-deftest port-tooling-test-user-eval-escapes-quotes ()
  "Strings containing quotes survive the Elisp -> Clojure round trip."
  (let* ((session (port-eval-tests--make-session))
         sent)
    (cl-letf (((symbol-function 'port-client-send)
               (lambda (_conn s) (setq sent s))))
      (port-tooling-user-eval session "user" "(println \"hi\")" #'ignore))
    (should (string-match-p (regexp-quote "\"(println \\\"hi\\\")\"") sent))))

(provide 'port-eval-tests)

;;; port-eval-tests.el ends here

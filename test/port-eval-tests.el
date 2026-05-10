;;; port-eval-tests.el --- Tests for port-eval -*- lexical-binding: t -*-

;;; Commentary:

;; Tests for the eval-display dispatch and rendering helpers.  We
;; don't talk to a real prepl: we synthesize result alists and
;; capture what `message' would print and what gets emitted into a
;; fixture REPL buffer.

;;; Code:

(require 'buttercup)
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

(describe "port-eval--display-result"

  (it "shows the value in the minibuffer (default mode)"
    (let* ((port-eval-display 'minibuffer)
           (session (port-eval-tests--make-session))
           (port-default-session session)
           (msg (port-eval-tests--with-message
                 (lambda ()
                   (port-eval--display-result
                    '((:tag . :ok) (:val . "3")
                      (:out . "") (:err . "") (:ns . "user")))))))
      (expect msg :to-equal "=> 3")))

  (it "uses :ex-message for the minibuffer error blurb"
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
      (expect msg :to-equal "Divide by zero")))

  (it "falls back to :ex when :ex-message is missing"
    (let* ((port-eval-display 'minibuffer)
           (session (port-eval-tests--make-session))
           (port-default-session session)
           (msg (port-eval-tests--with-message
                 (lambda ()
                   (port-eval--display-result
                    '((:tag . :err)
                      (:ex . "boom") (:out . "") (:err . "")))))))
      (expect msg :to-equal "boom")))

  (it "echoes the value into the REPL when display is `both'"
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
              (expect (buffer-substring-no-properties (point-min) (point-max))
                      :to-match "42\nuser=> ")))
        (kill-buffer buf))))

  (it "always emits :out into the REPL, even in minibuffer mode"
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
              (expect (buffer-substring-no-properties (point-min) (point-max))
                      :to-match "side-effect\n")))
        (kill-buffer buf))))

  (it "truncates a multi-line value to its first line in the minibuffer"
    (let* ((port-eval-display 'minibuffer)
           (session (port-eval-tests--make-session))
           (port-default-session session)
           (msg (port-eval-tests--with-message
                 (lambda ()
                   (port-eval--display-result
                    '((:tag . :ok) (:val . "{:a 1\n :b 2}")
                      (:out . "") (:err . "") (:ns . "user")))))))
      (expect (string-prefix-p "=> {:a 1" msg) :to-be-truthy)
      (expect (string-suffix-p "…" msg) :to-be-truthy)
      (expect msg :not :to-match "\n"))))

(describe "port-eval--current-ns"

  (it "honours `clojure-find-ns' when bound"
    (let ((session (port-eval-tests--make-session)))
      (cl-letf (((symbol-function 'clojure-find-ns) (lambda () "my.ns")))
        (expect (port-eval--current-ns session) :to-equal "my.ns"))))

  (it "falls back to the regex-based extractor"
    (let ((session (port-eval-tests--make-session)))
      (with-temp-buffer
        (insert "(ns my.regex.ns)\n(defn foo [] :hi)\n")
        (cl-letf (((symbol-function 'clojure-find-ns) (lambda () nil)))
          (expect (port-eval--current-ns session)
                  :to-equal "my.regex.ns")))))

  (it "falls back to the user socket's tracked ns when the buffer has none"
    (let ((session (port-eval-tests--make-session)))
      (setf (port-client-current-ns (port-session-user-conn session))
            "lib.foo")
      (with-temp-buffer
        (cl-letf (((symbol-function 'clojure-find-ns) (lambda () nil)))
          (expect (port-eval--current-ns session)
                  :to-equal "lib.foo"))))))

(describe "port-current-buffer-ns"

  (it "recognises an `ns' form near the top of the buffer"
    (with-temp-buffer
      (insert ";; preamble\n(ns app.core\n  (:require [clojure.string :as str]))\n")
      (expect (port-current-buffer-ns) :to-equal "app.core")))

  (it "returns nil when no ns form is present"
    (with-temp-buffer
      (insert "(defn standalone [])\n")
      (expect (port-current-buffer-ns) :to-be nil))))

(describe "port-tooling-user-eval"

  (it "constructs the wire form with the namespace and code"
    (let* ((session (port-eval-tests--make-session))
           (port-print-length 50)
           (port-print-level 5)
           sent)
      (cl-letf (((symbol-function 'port-client-send)
                 (lambda (_conn s) (setq sent s))))
        (port-tooling-user-eval session "my.ns" "(+ 1 2)" #'ignore))
      (expect sent :to-match
              "(port\\.tooling/-user-eval [0-9]+ (quote my\\.ns)")
      ;; The code is sent as a properly quoted Clojure string literal.
      (expect sent :to-match (regexp-quote "\"(+ 1 2)\""))
      ;; The print-length and print-level integers follow.
      (expect sent :to-match "\" 50 5)$")))

  (it "passes nil through when `port-print-length' / `port-print-level' are nil"
    (let* ((session (port-eval-tests--make-session))
           (port-print-length nil)
           (port-print-level nil)
           sent)
      (cl-letf (((symbol-function 'port-client-send)
                 (lambda (_conn s) (setq sent s))))
        (port-tooling-user-eval session "user" "x" #'ignore))
      (expect sent :to-match "\" nil nil)$")))

  (it "survives the Elisp -> Clojure round trip on quoted strings"
    (let* ((session (port-eval-tests--make-session))
           sent)
      (cl-letf (((symbol-function 'port-client-send)
                 (lambda (_conn s) (setq sent s))))
        (port-tooling-user-eval session "user" "(println \"hi\")" #'ignore))
      (expect sent :to-match
              (regexp-quote "\"(println \\\"hi\\\")\"")))))

(describe "port-eval--summary-line"

  (it "passes single-line values through unchanged"
    (expect (port-eval--summary-line "42") :to-equal "42")
    (expect (port-eval--summary-line "{:a 1, :b 2}") :to-equal "{:a 1, :b 2}")
    (expect (port-eval--summary-line nil) :to-be nil))

  (it "truncates multi-line values to the first line plus an ellipsis"
    (let ((s (port-eval--summary-line "{:a 1\n :b 2\n :c 3}")))
      (expect (string-prefix-p "{:a 1" s) :to-be-truthy)
      (expect (string-suffix-p "…" s) :to-be-truthy)
      (expect s :not :to-match "\n"))))

(provide 'port-eval-tests)

;;; port-eval-tests.el ends here

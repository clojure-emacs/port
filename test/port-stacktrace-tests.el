;;; port-stacktrace-tests.el --- Tests for port-stacktrace -*- lexical-binding: t -*-

;;; Commentary:

;; Tests for the stacktrace parser and renderer.

;;; Code:

(require 'buttercup)
(require 'port-client)
(require 'port-stacktrace)

(defconst port-stacktrace-tests--sample
  (concat "{:via [{:type clojure.lang.ExceptionInfo"
          " :message \"boom\""
          " :data {:foo 1}"
          " :at [user$eval123 invokeStatic \"REPL Input\" 1]}]"
          " :trace [[user$eval123 invokeStatic \"REPL Input\" 1]"
          "         [clojure.lang.Compiler eval \"Compiler.java\" 7194]"
          "         [my.app$frob invokeStatic \"app.clj\" 42]]"
          " :cause \"boom\""
          " :data {:foo 1}}")
  "A sample printed Throwable->map for tests.")

(describe "port-stacktrace-parse"

  (it "returns the parsed alist for a real Throwable->map shape"
    (let ((m (port-stacktrace-parse port-stacktrace-tests--sample)))
      (expect m :to-be-truthy)
      (expect (alist-get :cause m) :to-equal "boom")
      (expect (length (alist-get :trace m)) :to-equal 3)))

  (it "returns nil for non-map inputs"
    (expect (port-stacktrace-parse "42") :to-be nil)
    (expect (port-stacktrace-parse "[1 2 3]") :to-be nil)
    (expect (port-stacktrace-parse "not edn at all") :to-be nil)))

(describe "port-stacktrace-display"

  (it "renders the cause line, ex-data, and trace section"
    (let* ((port-stacktrace-auto-open nil)
           (m (port-stacktrace-parse port-stacktrace-tests--sample))
           (buf (port-stacktrace-display m nil)))
      (unwind-protect
          (with-current-buffer buf
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (expect text :to-match "ExceptionInfo")
              (expect text :to-match "boom")
              (expect text :to-match ":foo 1")
              (expect text :to-match "Trace:")
              (expect text :to-match "app.clj:42")))
        (kill-buffer buf))))

  (it "filters Clojure/Java internals when the toggle is on"
    (let* ((port-stacktrace-auto-open nil)
           (port-stacktrace-hide-clojure-internals t)
           (m (port-stacktrace-parse port-stacktrace-tests--sample))
           (buf (port-stacktrace-display m nil)))
      (unwind-protect
          (with-current-buffer buf
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              ;; clojure.lang.Compiler frame should be hidden.
              (expect text :not :to-match "Compiler.java")
              (expect text :to-match "frames hidden")))
        (kill-buffer buf))))

  (it "keeps every frame when the toggle is off"
    (let* ((port-stacktrace-auto-open nil)
           (port-stacktrace-hide-clojure-internals nil)
           (m (port-stacktrace-parse port-stacktrace-tests--sample))
           (buf (port-stacktrace-display m nil)))
      (unwind-protect
          (with-current-buffer buf
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (expect text :to-match "Compiler.java")))
        (kill-buffer buf))))

  (it "tags rendered frames with `port-stacktrace-frame'"
    (let* ((port-stacktrace-auto-open nil)
           (port-stacktrace-hide-clojure-internals nil)
           (m (port-stacktrace-parse port-stacktrace-tests--sample))
           (buf (port-stacktrace-display m nil)))
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            (re-search-forward "app.clj")
            (expect (get-text-property (point) 'port-stacktrace-frame)
                    :to-be-truthy))
        (kill-buffer buf)))))

(describe "port-stacktrace-pop-from-result"
  (it "is a no-op on results without a parseable :ex"
    (expect (port-stacktrace-pop-from-result '((:tag . :err)))
            :to-be nil)
    (expect (port-stacktrace-pop-from-result
             '((:tag . :err) (:ex . "garbage")))
            :to-be nil)))

(provide 'port-stacktrace-tests)

;;; port-stacktrace-tests.el ends here

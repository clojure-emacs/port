;;; port-stacktrace-tests.el --- Tests for port-stacktrace -*- lexical-binding: t -*-

;;; Commentary:

;; Tests for the stacktrace parser and renderer.

;;; Code:

(require 'ert)
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

(ert-deftest port-stacktrace-test-parse-returns-alist ()
  (let ((m (port-stacktrace-parse port-stacktrace-tests--sample)))
    (should m)
    (should (equal "boom" (alist-get :cause m)))
    (should (= 3 (length (alist-get :trace m))))))

(ert-deftest port-stacktrace-test-parse-rejects-non-map ()
  (should (null (port-stacktrace-parse "42")))
  (should (null (port-stacktrace-parse "[1 2 3]")))
  (should (null (port-stacktrace-parse "not edn at all"))))

(ert-deftest port-stacktrace-test-display-renders-cause ()
  (let* ((port-stacktrace-auto-open nil)
         (m (port-stacktrace-parse port-stacktrace-tests--sample))
         (buf (port-stacktrace-display m nil)))
    (unwind-protect
        (with-current-buffer buf
          (let ((text (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "ExceptionInfo" text))
            (should (string-match-p "boom" text))
            (should (string-match-p ":foo 1" text))
            (should (string-match-p "Trace:" text))
            (should (string-match-p "app.clj:42" text))))
      (kill-buffer buf))))

(ert-deftest port-stacktrace-test-display-filters-internals ()
  (let* ((port-stacktrace-auto-open nil)
         (port-stacktrace-hide-clojure-internals t)
         (m (port-stacktrace-parse port-stacktrace-tests--sample))
         (buf (port-stacktrace-display m nil)))
    (unwind-protect
        (with-current-buffer buf
          (let ((text (buffer-substring-no-properties (point-min) (point-max))))
            ;; clojure.lang.Compiler frame should be filtered out.
            (should-not (string-match-p "Compiler.java" text))
            (should (string-match-p "frames hidden" text))))
      (kill-buffer buf))))

(ert-deftest port-stacktrace-test-display-keeps-internals-when-disabled ()
  (let* ((port-stacktrace-auto-open nil)
         (port-stacktrace-hide-clojure-internals nil)
         (m (port-stacktrace-parse port-stacktrace-tests--sample))
         (buf (port-stacktrace-display m nil)))
    (unwind-protect
        (with-current-buffer buf
          (let ((text (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "Compiler.java" text))))
      (kill-buffer buf))))

(ert-deftest port-stacktrace-test-frame-property-set ()
  (let* ((port-stacktrace-auto-open nil)
         (port-stacktrace-hide-clojure-internals nil)
         (m (port-stacktrace-parse port-stacktrace-tests--sample))
         (buf (port-stacktrace-display m nil)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (re-search-forward "app.clj")
          (should (get-text-property (point) 'port-stacktrace-frame)))
      (kill-buffer buf))))

(ert-deftest port-stacktrace-test-pop-from-result-noop-on-bad-ex ()
  ;; No `:ex' field at all -> nothing to render, must not error.
  (should (null (port-stacktrace-pop-from-result '((:tag . :err)))))
  ;; Unparseable `:ex' string -> still no-op.
  (should (null (port-stacktrace-pop-from-result
                 '((:tag . :err) (:ex . "garbage"))))))

(provide 'port-stacktrace-tests)

;;; port-stacktrace-tests.el ends here

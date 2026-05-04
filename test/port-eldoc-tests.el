;;; port-eldoc-tests.el --- Tests for port-eldoc -*- lexical-binding: t -*-

;;; Commentary:

;; Unit tests that don't require a live prepl: target detection and
;; the result decoder.

;;; Code:

(require 'ert)
(require 'port-tooling)
(require 'port-eldoc)

(ert-deftest port-eldoc-test-decode-string ()
  ;; A printed Clojure string round-trips to its contents.
  (should (equal "hello" (port-tooling-decode-val "\"hello\"")))
  ;; Embedded escapes get unescaped.
  (should (equal "a\nb" (port-tooling-decode-val "\"a\\nb\""))))

(ert-deftest port-eldoc-test-decode-nil ()
  (should (eq nil (port-tooling-decode-val "nil"))))

(ert-deftest port-eldoc-test-decode-number ()
  (should (= 42 (port-tooling-decode-val "42"))))

(ert-deftest port-eldoc-test-decode-falls-through ()
  ;; Non-string values are returned unchanged.
  (should (eq nil (port-tooling-decode-val nil)))
  (should (= 7 (port-tooling-decode-val 7))))

(ert-deftest port-eldoc-test-target-inside-call ()
  (with-temp-buffer
    (set-syntax-table emacs-lisp-mode-syntax-table)
    (insert "(map inc [1 2 3])")
    (goto-char 8)  ;; inside the form, just after `inc'
    (should (equal "map" (port-eldoc--target)))))

(ert-deftest port-eldoc-test-target-outside-list ()
  (with-temp-buffer
    (set-syntax-table emacs-lisp-mode-syntax-table)
    (insert "foo")
    (goto-char 2)
    (should (null (port-eldoc--target)))))

(ert-deftest port-eldoc-test-query-substitutes ()
  (let ((q (port-eldoc--query "foo" "my.ns")))
    (should (string-match-p "find-ns (quote my.ns)" q))
    (should (string-match-p "ns-resolve ns (quote foo)" q))))

(provide 'port-eldoc-tests)

;;; port-eldoc-tests.el ends here

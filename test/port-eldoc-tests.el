;;; port-eldoc-tests.el --- Tests for port-eldoc -*- lexical-binding: t -*-

;;; Commentary:

;; Unit tests that don't require a live prepl: target detection and
;; the result decoder.

;;; Code:

(require 'buttercup)
(require 'port-tooling)
(require 'port-eldoc)

(describe "port-tooling-decode-val"

  (it "unwraps a printed Clojure string"
    (expect (port-tooling-decode-val "\"hello\"") :to-equal "hello"))

  (it "unescapes embedded sequences"
    (expect (port-tooling-decode-val "\"a\\nb\"") :to-equal "a\nb"))

  (it "decodes nil"
    (expect (port-tooling-decode-val "nil") :to-be nil))

  (it "decodes a number"
    (expect (port-tooling-decode-val "42") :to-equal 42))

  (it "leaves non-string values alone"
    (expect (port-tooling-decode-val nil) :to-be nil)
    (expect (port-tooling-decode-val 7) :to-equal 7)))

(describe "port-eldoc--target"

  (it "returns the function symbol when point is inside a call"
    (with-temp-buffer
      (set-syntax-table emacs-lisp-mode-syntax-table)
      (insert "(map inc [1 2 3])")
      (goto-char 8)  ;; inside the form, just after `inc'
      (expect (port-eldoc--target) :to-equal "map")))

  (it "returns nil when point isn't inside a list"
    (with-temp-buffer
      (set-syntax-table emacs-lisp-mode-syntax-table)
      (insert "foo")
      (goto-char 2)
      (expect (port-eldoc--target) :to-be nil))))

(describe "port-eldoc--query"
  (it "substitutes the namespace and symbol"
    (let ((q (port-eldoc--query "foo" "my.ns")))
      (expect q :to-match "find-ns (quote my.ns)")
      (expect q :to-match "ns-resolve ns (quote foo)"))))

(provide 'port-eldoc-tests)

;;; port-eldoc-tests.el ends here

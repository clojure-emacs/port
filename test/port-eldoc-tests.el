;;; port-eldoc-tests.el --- Tests for port-eldoc -*- lexical-binding: t -*-

;;; Commentary:

;; Unit tests that don't require a live prepl: target detection, the
;; arg-index walker, arglist parsing + highlighting, and the
;; map-vs-string format dispatcher.

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

  (it "returns the symbol at point when there is one"
    (with-temp-buffer
      (set-syntax-table emacs-lisp-mode-syntax-table)
      (insert "(map inc [1 2 3])")
      (goto-char 8)  ;; on `inc'
      (expect (port-eldoc--target) :to-equal "inc")))

  (it "falls back to the enclosing list head in whitespace"
    (with-temp-buffer
      (set-syntax-table emacs-lisp-mode-syntax-table)
      (insert "(map )")
      (goto-char 6)  ;; on the space between `map' and `)'
      (expect (port-eldoc--target) :to-equal "map")))

  (it "walks outward for nested calls in whitespace"
    (with-temp-buffer
      (set-syntax-table emacs-lisp-mode-syntax-table)
      (insert "(str (sub ))")
      (goto-char 11) ;; inside `(sub )', between `sub' and `)'
      (expect (port-eldoc--target) :to-equal "sub")))

  (it "returns the symbol even at top level"
    (with-temp-buffer
      (set-syntax-table emacs-lisp-mode-syntax-table)
      (insert "foo")
      (goto-char 2)
      (expect (port-eldoc--target) :to-equal "foo"))))


(describe "port-eldoc--current-arg-index"

  (it "returns 0 right after the head, before any arg"
    (with-temp-buffer
      (set-syntax-table emacs-lisp-mode-syntax-table)
      (insert "(str )")
      (goto-char 6)  ;; just before `)'
      (expect (port-eldoc--current-arg-index) :to-equal 0)))

  (it "returns 1 between the first and second arg"
    (with-temp-buffer
      (set-syntax-table emacs-lisp-mode-syntax-table)
      (insert "(map inc )")
      (goto-char 10)  ;; just before `)'
      (expect (port-eldoc--current-arg-index) :to-equal 1)))

  (it "returns nil at top level"
    (with-temp-buffer
      (set-syntax-table emacs-lisp-mode-syntax-table)
      (insert "foo bar")
      (goto-char 4)
      (expect (port-eldoc--current-arg-index) :to-be nil))))


(describe "port-eldoc--query"
  (it "substitutes the namespace and symbol"
    (let ((q (port-eldoc--query "foo" "my.ns")))
      (expect q :to-match "find-ns (quote my.ns)")
      (expect q :to-match "ns-resolve ns (quote foo)")))

  (it "honours overrides of `port-eldoc-form'"
    (let ((port-eldoc-form "(my-dialect/arglists '%s '%s)"))
      (expect (port-eldoc--query "foo" "my.ns")
              :to-equal "(my-dialect/arglists 'my.ns 'foo)"))))


(describe "port-eldoc--parse-arglist"

  (it "parses a flat arglist"
    (expect (port-eldoc--parse-arglist "[f coll]")
            :to-equal '(("f" "coll"))))

  (it "parses multi-arity arglists"
    (expect (port-eldoc--parse-arglist "([] [x] [x & rest])")
            :to-equal '(() ("x") ("x" "&" "rest"))))

  (it "returns nil for shapes it can't parse"
    (expect (port-eldoc--parse-arglist "[{:keys [a b]}]") :to-be nil)))


(describe "port-eldoc--pick-arity"

  (it "picks the arity whose length covers the index"
    (expect (port-eldoc--pick-arity '(("f" "coll") ("f" "coll" "&" "rs")) 0)
            :to-equal '("f" "coll"))
    (expect (port-eldoc--pick-arity '(("f" "coll") ("f" "coll" "&" "rs")) 2)
            :to-equal '("f" "coll" "&" "rs"))))


(describe "port-eldoc--highlight-arglist"

  (it "wraps the active param with `eldoc-highlight-function-argument'"
    (let* ((styled (port-eldoc--highlight-arglist "[f coll]" 1)))
      (expect styled :to-match "coll")
      (expect (text-property-any 0 (length styled)
                                 'face 'eldoc-highlight-function-argument
                                 styled)
              :to-be-truthy)))

  (it "falls back to the raw string when parsing fails"
    (expect (port-eldoc--highlight-arglist "[{:keys [a b]}]" 0)
            :to-equal "[{:keys [a b]}]"))

  (it "handles `& rest' by highlighting the rest param"
    (let* ((styled (port-eldoc--highlight-arglist "[x & rs]" 3))
           (pos (text-property-any 0 (length styled)
                                   'face 'eldoc-highlight-function-argument
                                   styled)))
      (expect pos :to-be-truthy)
      (expect (substring-no-properties styled pos (+ pos 2))
              :to-equal "rs"))))


(describe "port-eldoc-format-lispy-arglist"

  (it "renders name + highlighted arglist + first doc line"
    (let* ((info '((:name . "clojure.core/map")
                   (:arglists . "([f coll])")
                   (:doc . "Returns a lazy sequence.\nMore.")))
           (s (port-eldoc-format-lispy-arglist info 0)))
      (expect s :to-match "clojure.core/map")
      (expect s :to-match "coll")
      (expect s :to-match "Returns a lazy sequence\\.")
      (expect s :not :to-match "More\\.")))

  (it "drops the doc when none is present"
    (let* ((info '((:name . "f") (:arglists . "[x]")))
           (s (port-eldoc-format-lispy-arglist info 0)))
      (expect s :to-equal "f: [x]")))

  (it "returns nil when neither arglist nor doc are available"
    (expect (port-eldoc-format-lispy-arglist '((:name . "f")) 0)
            :to-be nil)))


(describe "port-eldoc--format dispatch"

  (it "passes strings through verbatim (legacy form templates)"
    (expect (port-eldoc--format "foo: [x]" 0) :to-equal "foo: [x]"))

  (it "calls the arglist formatter on alists"
    (let ((port-eldoc-arglist-formatter
           (lambda (info _idx) (format "got %S" info))))
      (expect (port-eldoc--format '((:name . "x")) 0)
              :to-equal "got ((:name . \"x\"))")))

  (it "returns nil for nil input"
    (expect (port-eldoc--format nil 0) :to-be nil))

  (it "honours a nil formatter (no display)"
    (let ((port-eldoc-arglist-formatter nil))
      (expect (port-eldoc--format '((:name . "x")) 0) :to-be nil))))

(provide 'port-eldoc-tests)

;;; port-eldoc-tests.el ends here

;;; port-completion-tests.el --- Tests for port-completion -*- lexical-binding: t -*-

;;; Commentary:

;; Tests for the bits of completion that don't need a live prepl: the
;; query builder, the response parser, and the per-namespace cache.

;;; Code:

(require 'buttercup)
(require 'port-completion)
(require 'port-tooling)

(defun port-completion-tests--clear ()
  "Reset the completion cache between tests."
  (clrhash port-completion--cache))

(describe "port-completion--query"

  (it "substitutes namespace and prefix into the form"
    (let ((q (port-completion--query "ma" "my.ns")))
      (expect q :to-match "find-ns (quote my.ns)")
      (expect q :to-match "prefix \"ma\"")))

  (it "escapes quotes inside the prefix"
    (let ((q (port-completion--query "a\"b" "user")))
      (expect q :to-match "prefix \"a\\\\\"b\"")))

  (it "honours overrides of `port-completion-form'"
    (let ((port-completion-form "(my-dialect/complete '%s %S)"))
      (expect (port-completion--query "ma" "user")
              :to-equal "(my-dialect/complete 'user \"ma\")"))))

(describe "port-completion--parse-response"

  (it "splits the printed string into a list of candidates"
    (expect (port-completion--parse-response
             '((:tag . :ok) (:val . "\"map\\nmapcat\\nmapv\"")))
            :to-equal '("map" "mapcat" "mapv")))

  (it "returns nil when the response isn't :ok"
    (expect (port-completion--parse-response
             '((:tag . :err) (:ex-message . "boom")))
            :to-be nil))

  (it "returns nil on an empty payload"
    (expect (port-completion--parse-response
             '((:tag . :ok) (:val . "\"\"")))
            :to-be nil)))

(describe "port-completion cache"

  (before-each (port-completion-tests--clear))
  (after-each  (port-completion-tests--clear))

  (it "stores and reads entries by namespace"
    (port-completion--store "user" '("map" "mapcat" "filter"))
    (expect (port-completion--cached-symbols "user")
            :to-equal '("map" "mapcat" "filter")))

  (it "honours the TTL"
    (port-completion--store "user" '("map"))
    ;; Backdate the entry past the TTL.
    (puthash "user" (cons (- (float-time) 9999.0) '("map"))
             port-completion--cache)
    (let ((port-completion-cache-ttl 1.0))
      (expect (port-completion--cached-symbols "user") :to-be nil)))

  (it "returns nil for unknown namespaces"
    (expect (port-completion--cached-symbols "no.such") :to-be nil))

  (it "skips pending sentinels"
    ;; A nil-timestamp entry means a warm-up is in flight.
    (puthash "user" (cons nil nil) port-completion--cache)
    (expect (port-completion--cached-symbols "user") :to-be nil))

  (it "is bypassed when caching is disabled"
    (port-completion--store "user" '("map"))
    (let ((port-completion-use-cache nil))
      (expect (port-completion--cached-symbols "user") :to-be nil))))

(describe "port-completion-invalidate"

  (before-each (port-completion-tests--clear))
  (after-each  (port-completion-tests--clear))

  (it "drops a single namespace when given one"
    (port-completion--store "user"   '("a"))
    (port-completion--store "my.app" '("b"))
    (port-completion-invalidate "user")
    (expect (port-completion--cached-symbols "user")   :to-be nil)
    (expect (port-completion--cached-symbols "my.app") :to-equal '("b")))

  (it "clears every entry when called without an argument"
    (port-completion--store "user"   '("a"))
    (port-completion--store "my.app" '("b"))
    (port-completion-invalidate)
    (expect (hash-table-count port-completion--cache) :to-equal 0)))

(describe "port-completion--candidates filters from the cache"

  (before-each (port-completion-tests--clear))
  (after-each  (port-completion-tests--clear))

  (it "returns only entries with the typed prefix"
    (port-completion--store "user" '("map" "mapcat" "mapv" "filter" "reduce"))
    (cl-letf (((symbol-function 'port-session-current-ns)
               (lambda (_) "user")))
      (let ((port-default-session 'sentinel))
        (expect (port-completion--candidates "ma")
                :to-equal '("map" "mapcat" "mapv"))
        (expect (port-completion--candidates "red")
                :to-equal '("reduce"))))))

(provide 'port-completion-tests)

;;; port-completion-tests.el ends here

;;; port-completion-tests.el --- Tests for port-completion -*- lexical-binding: t -*-

;;; Commentary:

;; Tests for the bits of completion that don't need a live prepl: the
;; query builder and result parsing via the decode helper.

;;; Code:

(require 'buttercup)
(require 'port-completion)
(require 'port-tooling)

(describe "port-completion--query"

  (it "substitutes namespace and prefix into the form"
    (let ((q (port-completion--query "ma" "my.ns")))
      (expect q :to-match "find-ns (quote my.ns)")
      (expect q :to-match "prefix \"ma\"")))

  (it "escapes quotes inside the prefix"
    (let ((q (port-completion--query "a\"b" "user")))
      (expect q :to-match "prefix \"a\\\\\"b\""))))

(describe "port-tooling-decode-val with a newline-joined list"
  (it "returns the unwrapped multi-line string"
    ;; The Clojure side returns a newline-joined string, which our
    ;; decoder unwraps from the printed-string form.  The CAPF then
    ;; splits it.
    (expect (port-tooling-decode-val "\"map\\nmapcat\\nmapv\"")
            :to-equal "map\nmapcat\nmapv")))

(provide 'port-completion-tests)

;;; port-completion-tests.el ends here

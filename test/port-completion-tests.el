;;; port-completion-tests.el --- Tests for port-completion -*- lexical-binding: t -*-

;;; Commentary:

;; Tests for the bits of completion that don't need a live prepl: the
;; query builder and result parsing via the decode helper.

;;; Code:

(require 'ert)
(require 'port-completion)
(require 'port-tooling)

(ert-deftest port-completion-test-query-substitutes-ns-and-prefix ()
  (let ((q (port-completion--query "ma" "my.ns")))
    (should (string-match-p "find-ns (quote my.ns)" q))
    (should (string-match-p "prefix \"ma\"" q))))

(ert-deftest port-completion-test-query-escapes-prefix ()
  (let ((q (port-completion--query "a\"b" "user")))
    (should (string-match-p "prefix \"a\\\\\"b\"" q))))

(ert-deftest port-completion-test-decode-newline-list ()
  ;; The Clojure side returns a newline-joined string, which our decoder
  ;; unwraps from the printed-string form.  The CAPF then splits it.
  (should (equal "map\nmapcat\nmapv"
                 (port-tooling-decode-val "\"map\\nmapcat\\nmapv\""))))

(provide 'port-completion-tests)

;;; port-completion-tests.el ends here

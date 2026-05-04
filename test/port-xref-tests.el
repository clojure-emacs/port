;;; port-xref-tests.el --- Tests for port-xref -*- lexical-binding: t -*-

;;; Commentary:

;; Tests for the parts of find-definition that don't talk to a prepl:
;; the query builder and the decoded-result shape.

;;; Code:

(require 'ert)
(require 'port-tooling)
(require 'port-xref)

(ert-deftest port-xref-test-query-substitutes ()
  (let ((q (port-xref--query "foo" "my.ns")))
    (should (string-match-p "find-ns (quote my.ns)" q))
    (should (string-match-p "ns-resolve ns (quote foo)" q))
    (should (string-match-p ":file (:file m)" q))
    (should (string-match-p ":line (:line m)" q))))

(ert-deftest port-xref-test-decode-result-map ()
  (let* ((printed (concat "{:name \"clojure.core/map\","
                          " :file \"clojure/core.clj\","
                          " :line 2727,"
                          " :column 1}"))
         (m (port-tooling-decode-val printed)))
    (should (consp m))
    (should (equal "clojure.core/map" (alist-get :name m)))
    (should (equal "clojure/core.clj" (alist-get :file m)))
    (should (= 2727 (alist-get :line m)))))

(ert-deftest port-xref-test-decode-nil-result ()
  ;; When the symbol doesn't resolve, the Clojure form returns nil and
  ;; the printed val is "nil".  We expect Elisp nil after decoding.
  (should (eq nil (port-tooling-decode-val "nil"))))

(provide 'port-xref-tests)

;;; port-xref-tests.el ends here

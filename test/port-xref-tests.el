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
    (should (string-match-p ":file file" q))
    (should (string-match-p ":line (:line m)" q))
    (should (string-match-p "clojure.java.io/resource" q))
    (should (string-match-p ":url (some-> url str)" q))
    (should (string-match-p ":contents " q))))

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

(ert-deftest port-xref-test-jar-buffer-name ()
  (should (equal
           "*port-jar: clojure-1.11.1.jar!/clojure/core.clj*"
           (port-xref--jar-buffer-name
            "jar:file:/home/me/.m2/.../clojure-1.11.1.jar!/clojure/core.clj")))
  ;; Falls back gracefully when the URL doesn't match the expected shape.
  (should (string-prefix-p "*port-jar: "
                           (port-xref--jar-buffer-name "weird-url"))))

(ert-deftest port-xref-test-visit-jar-creates-buffer ()
  (let* ((url "jar:file:/tmp/foo.jar!/inner/x.clj")
         (contents "(ns inner.x)\n(defn hello [] :hi)\n")
         (existing (get-buffer (port-xref--jar-buffer-name url))))
    (when existing (kill-buffer existing))
    (let ((buf-name (port-xref--jar-buffer-name url)))
      (unwind-protect
          (save-window-excursion
            (port-xref--visit-jar url contents 2)
            (let ((buf (get-buffer buf-name)))
              (should buf)
              (with-current-buffer buf
                (should buffer-read-only)
                (should (equal url port-xref--jar-url))
                (should (= 2 (line-number-at-pos))))))
        (when (get-buffer buf-name)
          (kill-buffer buf-name))))))

(provide 'port-xref-tests)

;;; port-xref-tests.el ends here

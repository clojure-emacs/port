;;; port-xref-tests.el --- Tests for port-xref -*- lexical-binding: t -*-

;;; Commentary:

;; Tests for the parts of find-definition that don't talk to a prepl:
;; the query builder and the decoded-result shape.

;;; Code:

(require 'buttercup)
(require 'port-tooling)
(require 'port-xref)

(describe "port-xref--query"
  (it "substitutes namespace, symbol, and resource lookup"
    (let ((q (port-xref--query "foo" "my.ns")))
      (expect q :to-match "find-ns (quote my.ns)")
      (expect q :to-match "ns-resolve ns (quote foo)")
      (expect q :to-match ":file file")
      (expect q :to-match ":line (:line m)")
      (expect q :to-match "clojure.java.io/resource")
      (expect q :to-match ":url (some-> url str)")
      (expect q :to-match ":contents "))))

(describe "port-tooling-decode-val for an xref result map"

  (it "parses :name, :file, :line out of the printed map"
    (let* ((printed (concat "{:name \"clojure.core/map\","
                            " :file \"clojure/core.clj\","
                            " :line 2727,"
                            " :column 1}"))
           (m (port-tooling-decode-val printed)))
      (expect (consp m) :to-be-truthy)
      (expect (alist-get :name m) :to-equal "clojure.core/map")
      (expect (alist-get :file m) :to-equal "clojure/core.clj")
      (expect (alist-get :line m) :to-equal 2727)))

  (it "returns Elisp nil when the symbol doesn't resolve"
    ;; The Clojure form returns nil and the printed val is "nil".
    (expect (port-tooling-decode-val "nil") :to-be nil)))

(describe "port-xref--jar-buffer-name"

  (it "extracts the jar name and inner path from a jar: URL"
    (expect (port-xref--jar-buffer-name
             "jar:file:/home/me/.m2/.../clojure-1.11.1.jar!/clojure/core.clj")
            :to-equal
            "*port-jar: clojure-1.11.1.jar!/clojure/core.clj*"))

  (it "falls back gracefully on an unrecognised URL shape"
    (expect (port-xref--jar-buffer-name "weird-url")
            :to-match "\\`\\*port-jar: ")))

(describe "port-xref--visit-jar"
  (it "creates a read-only buffer with the jar contents and jumps to LINE"
    (let* ((url "jar:file:/tmp/foo.jar!/inner/x.clj")
           (contents "(ns inner.x)\n(defn hello [] :hi)\n")
           (buf-name (port-xref--jar-buffer-name url))
           (existing (get-buffer buf-name)))
      (when existing (kill-buffer existing))
      (unwind-protect
          (save-window-excursion
            (port-xref--visit-jar url contents 2)
            (let ((buf (get-buffer buf-name)))
              (expect buf :to-be-truthy)
              (with-current-buffer buf
                (expect buffer-read-only :to-be-truthy)
                (expect port-xref--jar-url :to-equal url)
                (expect (line-number-at-pos) :to-equal 2))))
        (when (get-buffer buf-name)
          (kill-buffer buf-name))))))

(provide 'port-xref-tests)

;;; port-xref-tests.el ends here

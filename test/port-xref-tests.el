;;; port-xref-tests.el --- Tests for port-xref -*- lexical-binding: t -*-

;;; Commentary:

;; Tests for the parts of the xref backend that don't talk to a prepl:
;; the query builders, the decoded-result-to-xref-item mapping, the
;; jar-buffer helpers, and the setup/teardown hook plumbing.

;;; Code:

(require 'buttercup)
(require 'port-tooling)
(require 'port-xref)
(require 'xref)

(describe "port-xref--query"
  (it "substitutes namespace, symbol, and resource lookup"
    (let ((q (port-xref--query "foo" "my.ns")))
      (expect q :to-match "find-ns (quote my.ns)")
      (expect q :to-match "ns-resolve ns (quote foo)")
      (expect q :to-match ":file file")
      (expect q :to-match ":line (:line m)")
      (expect q :to-match "clojure.java.io/resource")
      (expect q :to-match ":url (some-> url str)")
      (expect q :to-match ":contents ")))

  (it "honours overrides of `port-xref-form'"
    (let ((port-xref-form "(my-dialect/find-def '%s '%s)"))
      (expect (port-xref--query "foo" "my.ns")
              :to-equal "(my-dialect/find-def 'my.ns 'foo)"))))

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

(describe "port-xref--apropos-query"
  (it "compiles the pattern into a Clojure regex via re-pattern"
    (let ((q (port-xref--apropos-query "foo")))
      (expect q :to-match "re-pattern \"foo\"")
      (expect q :to-match "all-ns")
      (expect q :to-match ":name")
      (expect q :to-match ":file")
      (expect q :to-match ":line")))

  (it "honours overrides of `port-xref-apropos-form'"
    (let ((port-xref-apropos-form "(my.dialect/apropos %S)"))
      (expect (port-xref--apropos-query "needle")
              :to-equal "(my.dialect/apropos \"needle\")"))))


(describe "port-xref--decoded->item"

  (it "returns an xref-item with a file-location for an absolute existing path"
    (let* ((tmp (make-temp-file "port-xref-test"))
           (decoded `((:name . "my.ns/foo")
                      (:file . ,tmp)
                      (:line . 3))))
      (unwind-protect
          (let ((item (port-xref--decoded->item "foo" decoded)))
            (expect item :to-be-truthy)
            (expect (xref-item-summary item) :to-equal "my.ns/foo")
            (let ((loc (xref-item-location item)))
              (expect (xref-location-line loc) :to-equal 3)))
        (delete-file tmp))))

  (it "falls back to project-relative path when file isn't absolute"
    (let* ((dir (make-temp-file "port-xref-rel" t))
           (file (expand-file-name "rel.clj" dir))
           (default-directory dir))
      (with-temp-file file (insert "(ns rel)\n"))
      (unwind-protect
          (let ((item (port-xref--decoded->item
                       "rel/x"
                       '((:name . "rel/x")
                         (:file . "rel.clj")
                         (:line . 1)))))
            (expect item :to-be-truthy)
            (let ((loc (xref-item-location item)))
              (expect (xref-location-line loc) :to-equal 1)))
        (delete-directory dir t))))

  (it "returns nil when no usable location is present"
    (expect (port-xref--decoded->item
             "x" '((:name . "x") (:file) (:line)))
            :to-be nil))

  (it "materialises a jar buffer location for jar URLs"
    (let* ((url "jar:file:/tmp/sample.jar!/inner/x.clj")
           (contents "(ns inner.x)\n(defn hello [] :hi)\n")
           (buf-name (port-xref--jar-buffer-name url))
           (existing (get-buffer buf-name)))
      (when existing (kill-buffer existing))
      (unwind-protect
          (let ((item (port-xref--decoded->item
                       "inner.x/hello"
                       `((:name . "inner.x/hello")
                         (:file . "inner/x.clj")
                         (:line . 2)
                         (:url . ,url)
                         (:contents . ,contents)))))
            (expect item :to-be-truthy)
            (let ((loc (xref-item-location item)))
              (expect (xref-buffer-location-buffer loc)
                      :to-be (get-buffer buf-name))))
        (when (get-buffer buf-name)
          (kill-buffer buf-name))))))


(describe "port-xref--apropos-row->item"

  (it "builds a file-location item with a doc-augmented summary"
    (let* ((tmp (make-temp-file "port-xref-apropos"))
           (item (port-xref--apropos-row->item
                  `((:name . "my.ns/foo")
                    (:file . ,tmp)
                    (:line . 5)
                    (:doc  . "computes foo")))))
      (unwind-protect
          (progn
            (expect item :to-be-truthy)
            (expect (xref-item-summary item)
                    :to-equal "my.ns/foo — computes foo"))
        (delete-file tmp))))

  (it "drops the doc when none is present"
    (let* ((tmp (make-temp-file "port-xref-apropos"))
           (item (port-xref--apropos-row->item
                  `((:name . "my.ns/bar")
                    (:file . ,tmp)
                    (:line . 1)))))
      (unwind-protect
          (expect (xref-item-summary item) :to-equal "my.ns/bar")
        (delete-file tmp))))

  (it "returns nil when the file can't be resolved locally"
    (expect (port-xref--apropos-row->item
             '((:name . "x") (:file . "does/not/exist.clj") (:line . 1)))
            :to-be nil)))


(describe "port-xref-backend"

  (it "returns 'port when a session is bound"
    (let ((port-default-session 'sentinel))
      (expect (port-xref-backend) :to-be 'port)))

  (it "returns nil without an active session"
    (let ((port-default-session nil))
      (expect (port-xref-backend) :to-be nil))))


(describe "xref-backend-identifier-completion-table for backend 'port"

  (before-each (clrhash port-completion--cache))
  (after-each  (clrhash port-completion--cache))

  (it "returns the cached symbol list for the current namespace"
    (port-completion--store "my.ns" '("foo" "bar" "baz"))
    (cl-letf (((symbol-function 'port-session-current-ns)
               (lambda (_) "my.ns")))
      (let ((port-default-session 'sentinel))
        (expect (xref-backend-identifier-completion-table 'port)
                :to-equal '("foo" "bar" "baz")))))

  (it "returns nil when the cache is cold"
    (cl-letf (((symbol-function 'port-session-current-ns)
               (lambda (_) "no.cache")))
      (let ((port-default-session 'sentinel))
        (expect (xref-backend-identifier-completion-table 'port)
                :to-be nil))))

  (it "returns nil when no session is bound"
    (let ((port-default-session nil))
      (expect (xref-backend-identifier-completion-table 'port)
              :to-be nil))))


(describe "port-xref setup / teardown"

  (it "adds and removes the backend on `xref-backend-functions'"
    (with-temp-buffer
      (port-xref-setup)
      (expect (memq #'port-xref-backend xref-backend-functions)
              :to-be-truthy)
      (port-xref-teardown)
      (expect (memq #'port-xref-backend xref-backend-functions)
              :to-be nil))))


(describe "port-xref--jar-buffer-name"

  (it "extracts the jar name and inner path from a jar: URL"
    (expect (port-xref--jar-buffer-name
             "jar:file:/home/me/.m2/.../clojure-1.11.1.jar!/clojure/core.clj")
            :to-equal
            "*port-jar: clojure-1.11.1.jar!/clojure/core.clj*"))

  (it "falls back gracefully on an unrecognised URL shape"
    (expect (port-xref--jar-buffer-name "weird-url")
            :to-match "\\`\\*port-jar: ")))

(describe "port-xref--get-or-create-jar-buffer"
  (it "creates a read-only Clojure-mode buffer with the contents"
    (let* ((url "jar:file:/tmp/foo.jar!/inner/x.clj")
           (contents "(ns inner.x)\n(defn hello [] :hi)\n")
           (buf-name (port-xref--jar-buffer-name url))
           (existing (get-buffer buf-name)))
      (when existing (kill-buffer existing))
      (unwind-protect
          (let ((buf (port-xref--get-or-create-jar-buffer url contents)))
            (expect buf :to-be (get-buffer buf-name))
            (with-current-buffer buf
              (expect buffer-read-only :to-be-truthy)
              (expect port-xref--jar-url :to-equal url)))
        (when (get-buffer buf-name)
          (kill-buffer buf-name)))))

  (it "reuses an existing buffer for the same URL"
    (let* ((url "jar:file:/tmp/foo.jar!/inner/y.clj")
           (contents "(ns inner.y)\n")
           (buf-name (port-xref--jar-buffer-name url)))
      (when (get-buffer buf-name) (kill-buffer buf-name))
      (unwind-protect
          (let ((first  (port-xref--get-or-create-jar-buffer url contents))
                (second (port-xref--get-or-create-jar-buffer url contents)))
            (expect first :to-be second))
        (when (get-buffer buf-name)
          (kill-buffer buf-name))))))

(provide 'port-xref-tests)

;;; port-xref-tests.el ends here

;;; port-stacktrace-tests.el --- Tests for port-stacktrace -*- lexical-binding: t -*-

;;; Commentary:

;; Tests for the stacktrace parser and renderer.

;;; Code:

(require 'buttercup)
(require 'port-client)
(require 'port-stacktrace)

(defconst port-stacktrace-tests--sample
  (concat "{:via [{:type clojure.lang.ExceptionInfo"
          " :message \"boom\""
          " :data {:foo 1}"
          " :at [user$eval123 invokeStatic \"REPL Input\" 1]}]"
          " :trace [[user$eval123 invokeStatic \"REPL Input\" 1]"
          "         [clojure.lang.Compiler eval \"Compiler.java\" 7194]"
          "         [my.app$frob invokeStatic \"app.clj\" 42]]"
          " :cause \"boom\""
          " :data {:foo 1}}")
  "A sample printed Throwable->map for tests.")

(describe "port-stacktrace-parse"

  (it "returns the parsed alist for a real Throwable->map shape"
    (let ((m (port-stacktrace-parse port-stacktrace-tests--sample)))
      (expect m :to-be-truthy)
      (expect (alist-get :cause m) :to-equal "boom")
      (expect (length (alist-get :trace m)) :to-equal 3)))

  (it "returns nil for non-map inputs"
    (expect (port-stacktrace-parse "42") :to-be nil)
    (expect (port-stacktrace-parse "[1 2 3]") :to-be nil)
    (expect (port-stacktrace-parse "not edn at all") :to-be nil)))

(describe "port-stacktrace-display"

  (it "renders the cause line, ex-data, and trace section"
    (let* ((port-stacktrace-auto-open nil)
           (m (port-stacktrace-parse port-stacktrace-tests--sample))
           (buf (port-stacktrace-display m nil)))
      (unwind-protect
          (with-current-buffer buf
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (expect text :to-match "ExceptionInfo")
              (expect text :to-match "boom")
              (expect text :to-match ":foo 1")
              (expect text :to-match "Trace:")
              (expect text :to-match "app.clj:42")))
        (kill-buffer buf))))

  (it "filters Clojure/Java internals when the toggle is on"
    (let* ((port-stacktrace-auto-open nil)
           (port-stacktrace-hide-clojure-internals t)
           (m (port-stacktrace-parse port-stacktrace-tests--sample))
           (buf (port-stacktrace-display m nil)))
      (unwind-protect
          (with-current-buffer buf
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              ;; clojure.lang.Compiler frame should be hidden.
              (expect text :not :to-match "Compiler.java")
              (expect text :to-match "frames hidden")))
        (kill-buffer buf))))

  (it "keeps every frame when the toggle is off"
    (let* ((port-stacktrace-auto-open nil)
           (port-stacktrace-hide-clojure-internals nil)
           (m (port-stacktrace-parse port-stacktrace-tests--sample))
           (buf (port-stacktrace-display m nil)))
      (unwind-protect
          (with-current-buffer buf
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (expect text :to-match "Compiler.java")))
        (kill-buffer buf))))

  (it "tags rendered frames with `port-stacktrace-frame'"
    (let* ((port-stacktrace-auto-open nil)
           (port-stacktrace-hide-clojure-internals nil)
           (m (port-stacktrace-parse port-stacktrace-tests--sample))
           (buf (port-stacktrace-display m nil)))
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            (re-search-forward "app.clj")
            (expect (get-text-property (point) 'port-stacktrace-frame)
                    :to-be-truthy))
        (kill-buffer buf)))))

(describe "port-stacktrace-pop-from-result"
  (it "is a no-op on results without a parseable :ex"
    (expect (port-stacktrace-pop-from-result '((:tag . :err)))
            :to-be nil)
    (expect (port-stacktrace-pop-from-result
             '((:tag . :err) (:ex . "garbage")))
            :to-be nil)))

(describe "port-stacktrace-frame-form"
  (it "embeds the file path twice (resource lookup + echo)"
    (let ((form (format port-stacktrace-frame-form
                        "clojure/core.clj" "clojure/core.clj")))
      (expect form :to-match "clojure.java.io/resource \"clojure/core.clj\"")
      (expect form :to-match ":file \"clojure/core.clj\"")
      (expect form :to-match "\\.startsWith")
      (expect form :to-match "slurp url"))))

(describe "port-stacktrace--visit-resolved"

  (it "opens a jar buffer when the URL is a jar URL with contents"
    (let* ((url "jar:file:/tmp/foo.jar!/inner/stack.clj")
           (buf-name (port-xref--jar-buffer-name url))
           (decoded `((:file . "inner/stack.clj")
                      (:url  . ,url)
                      (:contents . "(ns inner.stack)\n(defn boom [] :no)\n"))))
      (when (get-buffer buf-name) (kill-buffer buf-name))
      (unwind-protect
          (save-window-excursion
            (port-stacktrace--visit-resolved decoded 2)
            (let ((buf (get-buffer buf-name)))
              (expect buf :to-be-truthy)
              (with-current-buffer buf
                (expect buffer-read-only :to-be-truthy)
                (expect (line-number-at-pos) :to-equal 2))))
        (when (get-buffer buf-name)
          (kill-buffer buf-name)))))

  (it "visits the path stripped from a file: URL when accessible"
    (let* ((tmp (make-temp-file "port-stack-resolved" nil ".clj"))
           (decoded `((:file . "x.clj") (:url . ,(concat "file:" tmp)))))
      (unwind-protect
          (save-window-excursion
            (with-temp-file tmp (insert "(ns x)\n"))
            (port-stacktrace--visit-resolved decoded 1)
            (expect (buffer-file-name) :to-equal tmp))
        (when (get-file-buffer tmp)
          (kill-buffer (get-file-buffer tmp)))
        (delete-file tmp))))

  (it "messages and bails when no usable target is present"
    (let ((messaged nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (setq messaged (apply #'format fmt args)))))
        (port-stacktrace--visit-resolved
         '((:file . "x.clj") (:url . "weird-protocol://nope")) 3))
      (expect messaged :to-match "no usable target"))))

(provide 'port-stacktrace-tests)

;;; port-stacktrace-tests.el ends here

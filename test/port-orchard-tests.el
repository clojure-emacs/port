;;; port-orchard-tests.el --- Tests for port-orchard -*- lexical-binding: t -*-

;;; Commentary:

;; Tests that the Orchard / Compliment form templates substitute
;; cleanly and that `port-orchard--apply' flips the right defcustoms
;; based on the probe result.  Actually round-tripping through a JVM
;; with Orchard on the classpath is out of scope for the unit tests.

;;; Code:

(require 'buttercup)
(require 'cl-lib)
(require 'port-completion)
(require 'port-eldoc)
(require 'port-mode)
(require 'port-orchard)
(require 'port-xref)

(describe "Orchard form templates"

  (it "doc form substitutes namespace and symbol"
    (let ((form (format port-orchard-doc-form "my.ns" "foo")))
      (expect form :to-match "orchard.info/info (quote my.ns) (quote foo)")
      (expect form :to-match "See also:")))

  (it "eldoc form returns an arglists string"
    (let ((form (format port-orchard-eldoc-form "my.ns" "foo")))
      (expect form :to-match "orchard.info/info (quote my.ns) (quote foo)")
      (expect form :to-match ":arglists m")))

  (it "apropos form quotes the pattern as a Clojure string literal"
    (let ((form (format port-orchard-apropos-form "foo")))
      (expect form :to-match "orchard.apropos/find-symbols")
      (expect form :to-match "re-pattern \"foo\"")))

  (it "xref form returns the Port-shaped result map"
    (let ((form (format port-orchard-xref-form "my.ns" "foo")))
      (expect form :to-match "orchard.info/info (quote my.ns) (quote foo)")
      (expect form :to-match ":file file")
      (expect form :to-match ":line (:line m)")
      (expect form :to-match ":column (:column m)")
      (expect form :to-match ":contents")))

  (it "compliment completion form binds ns and prefix"
    (let ((form (format port-compliment-completion-form "my.ns" "ma")))
      (expect form :to-match "compliment.core/completions")
      (expect form :to-match "(quote my.ns)")
      (expect form :to-match "\"ma\""))))

(describe "port-orchard--apply"

  ;; `port-orchard--apply' mutates user-visible defcustoms via `setq'.
  ;; Buttercup wraps each `it' body in a lexical closure; under
  ;; lexical-binding a `let'-binding of these vars in the closure is
  ;; lexical even though the defcustom forms make them special at
  ;; runtime.  Save & restore explicitly via `unwind-protect' so the
  ;; mutation doesn't leak across test files.
  (cl-flet ((with-saved-forms (body)
              (let ((orig-doc       port-doc-form)
                    (orig-eldoc     port-eldoc-form)
                    (orig-apropos   port-apropos-form)
                    (orig-xref      port-xref-form)
                    (orig-complete  port-completion-form))
                (unwind-protect (funcall body)
                  (setq port-doc-form        orig-doc
                        port-eldoc-form      orig-eldoc
                        port-apropos-form    orig-apropos
                        port-xref-form       orig-xref
                        port-completion-form orig-complete)))))

    (it "swaps all five forms when both probes are :ok"
      (with-saved-forms
       (lambda ()
         (let ((enabled (port-orchard--apply '((:orchard . :ok)
                                               (:compliment . :ok)))))
           (expect enabled :to-equal '("doc" "eldoc" "apropos" "xref" "completion"))
           (expect port-doc-form        :to-equal port-orchard-doc-form)
           (expect port-eldoc-form      :to-equal port-orchard-eldoc-form)
           (expect port-apropos-form    :to-equal port-orchard-apropos-form)
           (expect port-xref-form       :to-equal port-orchard-xref-form)
           (expect port-completion-form :to-equal port-compliment-completion-form)))))

    (it "leaves completion alone when only Orchard is present"
      (with-saved-forms
       (lambda ()
         (let ((orig-completion port-completion-form)
               (enabled (port-orchard--apply '((:orchard . :ok)
                                               (:compliment . :missing)))))
           (expect enabled :to-equal '("doc" "eldoc" "apropos" "xref"))
           (expect port-doc-form        :to-equal port-orchard-doc-form)
           (expect port-completion-form :to-equal orig-completion)))))

    (it "swaps only completion when only Compliment is present"
      (with-saved-forms
       (lambda ()
         (let ((orig-doc port-doc-form)
               (enabled (port-orchard--apply '((:orchard . :missing)
                                               (:compliment . :ok)))))
           (expect enabled :to-equal '("completion"))
           (expect port-doc-form        :to-equal orig-doc)
           (expect port-completion-form :to-equal port-compliment-completion-form)))))

    (it "returns nil when neither is available"
      (with-saved-forms
       (lambda ()
         (let ((orig-doc port-doc-form)
               (orig-completion port-completion-form)
               (enabled (port-orchard--apply '((:orchard . :missing)
                                               (:compliment . :missing)))))
           (expect enabled :to-be nil)
           (expect port-doc-form        :to-equal orig-doc)
           (expect port-completion-form :to-equal orig-completion)))))))

(provide 'port-orchard-tests)

;;; port-orchard-tests.el ends here

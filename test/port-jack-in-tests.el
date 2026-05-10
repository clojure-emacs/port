;;; port-jack-in-tests.el --- Tests for port-jack-in -*- lexical-binding: t -*-

;;; Commentary:

;; Tests for project detection, command construction, and the server
;; form builder.  We don't try to spawn a real JVM here.

;;; Code:

(require 'buttercup)
(require 'cl-lib)
(require 'port-jack-in)

(defmacro port-jack-in-tests--with-fixture (markers &rest body)
  "Create a temporary directory with each filename in MARKERS as an
empty file, run BODY with `default-directory' bound to it, then
clean up."
  (declare (indent 1))
  `(let ((root (file-name-as-directory (make-temp-file "port-fixture" t))))
     (unwind-protect
         (let ((default-directory root))
           (dolist (m ,markers)
             (with-temp-file (expand-file-name m root) (insert "")))
           ,@body)
       (delete-directory root t))))

(describe "project detection"

  (it "spots tools.deps"
    (port-jack-in-tests--with-fixture '("deps.edn")
      (let ((root (port-jack-in--detect-project-root)))
        (expect (file-equal-p root default-directory) :to-be-truthy)
        (expect (port-jack-in--detect-project-type root)
                :to-be 'tools-deps))))

  (it "spots Leiningen"
    (port-jack-in-tests--with-fixture '("project.clj")
      (let ((root (port-jack-in--detect-project-root)))
        (expect (port-jack-in--detect-project-type root)
                :to-be 'leiningen))))

  (it "spots babashka"
    (port-jack-in-tests--with-fixture '("bb.edn")
      (let ((root (port-jack-in--detect-project-root)))
        (expect (port-jack-in--detect-project-type root)
                :to-be 'babashka))))

  (it "falls back to `bare' when no marker is present"
    (port-jack-in-tests--with-fixture '()
      (let ((root (port-jack-in--detect-project-root)))
        (expect (port-jack-in--detect-project-type root)
                :to-be 'bare))))

  (it "prefers deps.edn over project.clj over bb.edn"
    (port-jack-in-tests--with-fixture '("deps.edn" "project.clj" "bb.edn")
      (let ((root (port-jack-in--detect-project-root)))
        (expect (port-jack-in--detect-project-type root)
                :to-be 'tools-deps)))))

(describe "port-jack-in--server-form"
  (it "embeds the port and the prepl-server scaffolding"
    (let ((form (port-jack-in--server-form 6789)))
      (expect form :to-match ":port 6789")
      (expect form :to-match "clojure.core.server/start-server")
      (expect form :to-match "clojure.core.server/io-prepl")
      (expect form :to-match "@(promise)"))))

(describe "port-jack-in--build-command"

  (it "tools.deps invokes `clojure -e'"
    (let ((cmd (port-jack-in--build-command 'tools-deps 5555)))
      (expect (car cmd)   :to-equal "clojure")
      (expect (nth 1 cmd) :to-equal "-e")
      (expect (nth 2 cmd) :to-match ":port 5555")))

  (it "Leiningen routes through trampoline + clojure.main"
    (let ((cmd (port-jack-in--build-command 'leiningen 5555)))
      (expect (car cmd) :to-equal "lein")
      (expect (member "trampoline" cmd) :to-be-truthy)
      (expect (member "clojure.main" cmd) :to-be-truthy)
      (expect (cl-some (lambda (s) (string-match-p ":port 5555" s)) cmd)
              :to-be-truthy)))

  (it "bare projects also use the clojure CLI"
    (let ((cmd (port-jack-in--build-command 'bare 5555)))
      (expect (car cmd) :to-equal "clojure")))

  (it "babashka isn't supported yet -- raise a user-error"
    (expect (port-jack-in--build-command 'babashka 5555)
            :to-throw 'user-error)))

(provide 'port-jack-in-tests)

;;; port-jack-in-tests.el ends here

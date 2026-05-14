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
      (expect form :to-match "@(promise)")))

  (it "includes a pprint-based :valf when pretty-print is on (the default)"
    (let* ((port-jack-in-pretty-print t)
           (form (port-jack-in--server-form 6789)))
      (expect form :to-match ":valf")
      (expect form :to-match "clojure.pprint/pprint")
      (expect form :to-match "require 'clojure.pprint")))

  (it "omits :valf when pretty-print is off"
    (let* ((port-jack-in-pretty-print nil)
           (form (port-jack-in--server-form 6789)))
      (expect form :not :to-match ":valf")
      (expect form :not :to-match "clojure.pprint"))))

(describe "port-jack-in--build-command"

  (it "tools.deps invokes `clojure -M -e'"
    (let ((cmd (port-jack-in--build-command 'tools-deps 5555)))
      (expect (car cmd)   :to-equal "clojure")
      (expect (nth 1 cmd) :to-equal "-M")
      (expect (nth 2 cmd) :to-equal "-e")
      (expect (nth 3 cmd) :to-match ":port 5555")))

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

(describe "port-jack-in--build-command with extra-deps"

  (it "splices `-Sdeps' into the tools-deps command"
    (let* ((port-jack-in-extra-deps '((cider/orchard . "0.41.0")))
           (cmd (port-jack-in--build-command 'tools-deps 5555)))
      (expect (car cmd) :to-equal "clojure")
      (expect (member "-Sdeps" cmd) :to-be-truthy)
      (let ((sdeps (nth 1 (member "-Sdeps" cmd))))
        (expect sdeps :to-match "cider/orchard")
        (expect sdeps :to-match ":mvn/version \"0.41.0\""))))

  (it "splices multiple deps into one map"
    (let* ((port-jack-in-extra-deps
            '((cider/orchard . "0.41.0")
              (compliment/compliment . "0.8.0")))
           (cmd (port-jack-in--build-command 'tools-deps 5555))
           (sdeps (nth 1 (member "-Sdeps" cmd))))
      (expect sdeps :to-match "cider/orchard")
      (expect sdeps :to-match "compliment/compliment")))

  (it "splices chained update-in into the Leiningen command"
    (let* ((port-jack-in-extra-deps
            '((cider/orchard . "0.41.0")
              (compliment/compliment . "0.8.0")))
           (cmd (port-jack-in--build-command 'leiningen 5555)))
      (expect (car cmd) :to-equal "lein")
      ;; update-in appears twice (once per dep).
      (expect (length (seq-filter (lambda (x) (equal x "update-in")) cmd))
              :to-equal 2)
      (expect (cl-some (lambda (s)
                         (string-match-p "cider/orchard \"0.41.0\"" s))
                       cmd)
              :to-be-truthy)
      ;; trampoline still follows the chain.
      (expect (member "trampoline" cmd) :to-be-truthy)))

  (it "leaves the command untouched when extra-deps is nil"
    (let* ((port-jack-in-extra-deps nil)
           (cmd (port-jack-in--build-command 'tools-deps 5555)))
      (expect (member "-Sdeps" cmd) :to-be nil))))

(describe "port-jack-in--deps-edn"
  (it "renders a single dep"
    (expect (port-jack-in--deps-edn '((cider/orchard . "0.41.0")))
            :to-equal "{cider/orchard {:mvn/version \"0.41.0\"}}"))

  (it "space-joins multiple deps"
    (expect (port-jack-in--deps-edn
             '((a/b . "1") (c/d . "2")))
            :to-equal "{a/b {:mvn/version \"1\"} c/d {:mvn/version \"2\"}}")))

(describe "port-jack-in alias"
  (it "is an alias for `port'"
    (expect (symbol-function 'port-jack-in) :to-be 'port)))

(describe "port-jack-in-orchard-deps preset"
  (it "lists Orchard and Compliment"
    (expect (alist-get 'cider/orchard port-jack-in-orchard-deps)
            :to-be-truthy)
    (expect (alist-get 'compliment/compliment port-jack-in-orchard-deps)
            :to-be-truthy)))

(provide 'port-jack-in-tests)

;;; port-jack-in-tests.el ends here

;;; port-completion-tests.el --- Tests for port-completion -*- lexical-binding: t -*-

;;; Commentary:

;; Tests for the bits of completion that don't need a live prepl: the
;; query builder, the response parser, and the per-namespace cache.

;;; Code:

(require 'buttercup)
(require 'port-completion)
(require 'port-tooling)

(defun port-completion-tests--clear ()
  "Reset every cache slot between tests (per-ns + core)."
  (clrhash port-completion--cache)
  (setq port-completion--core-cache nil
        port-completion--core-cache-pending nil))

(describe "port-completion--query"

  (it "substitutes namespace and prefix into the form"
    (let ((q (port-completion--query "ma" "my.ns")))
      (expect q :to-match "find-ns (quote my.ns)")
      (expect q :to-match "prefix \"ma\"")))

  (it "escapes quotes inside the prefix"
    (let ((q (port-completion--query "a\"b" "user")))
      (expect q :to-match "prefix \"a\\\\\"b\"")))

  (it "honours overrides of `port-completion-form'"
    (let ((port-completion-form "(my-dialect/complete '%s %S)"))
      (expect (port-completion--query "ma" "user")
              :to-equal "(my-dialect/complete 'user \"ma\")")))

  (it "defaults the form to one that emits the tab-delimited shape"
    (let ((q (port-completion--query "" "my.ns")))
      (expect q :to-match "\\\\tc\\\\t")          ; class branch literal
      (expect q :to-match ":macro")
      (expect q :to-match ":arglists")
      (expect q :to-match "clojure.string/join"))))


(describe "port-completion--decode-row"

  (it "decodes a fully-populated row into a candidate alist"
    (expect (port-completion--decode-row "map\tf\tclojure.core")
            :to-equal
            '((:candidate . "map") (:type . :function) (:ns . "clojure.core"))))

  (it "drops :ns when the ns field is empty"
    (expect (port-completion--decode-row "do\ts\t")
            :to-equal '((:candidate . "do") (:type . :special-form))))

  (it "returns a plain string when both code and ns are empty"
    (expect (port-completion--decode-row "raw\t\t") :to-equal "raw")
    (expect (port-completion--decode-row "raw")     :to-equal "raw"))

  (it "passes unknown codes through as `:CODE' for forward-compat"
    (expect (port-completion--decode-row "thing\tzz\t")
            :to-equal '((:candidate . "thing") (:type . :zz))))

  (it "returns nil for rows with an empty name"
    ;; An empty :candidate would shadow every core entry in the merge,
    ;; so we drop the row entirely.
    (expect (port-completion--decode-row "\tf\tclojure.core") :to-be nil)
    (expect (port-completion--decode-row "") :to-be nil)))


(describe "port-completion--parse-response"

  (it "decodes the tab-delimited default shape"
    (expect (port-completion--parse-response
             '((:tag . :ok)
               (:val . "map\tf\tclojure.core\nmax\tf\tclojure.core")))
            :to-equal
            '(((:candidate . "map") (:type . :function) (:ns . "clojure.core"))
              ((:candidate . "max") (:type . :function) (:ns . "clojure.core")))))

  (it "splits the oldest newline-only string into a list of names"
    (expect (port-completion--parse-response
             '((:tag . :ok) (:val . "map\nmapcat\nmapv")))
            :to-equal '("map" "mapcat" "mapv")))

  (it "returns a Compliment-shaped list of alists verbatim"
    ;; With -data-eval, :val is already the parsed list of alists.
    (let ((rich '(((:candidate . "map") (:type . :function) (:ns . "clojure.core"))
                  ((:candidate . "max") (:type . :function) (:ns . "clojure.core")))))
      (expect (port-completion--parse-response
               `((:tag . :ok) (:val . ,rich)))
              :to-equal rich)))

  (it "returns nil when the response isn't :ok"
    (expect (port-completion--parse-response
             '((:tag . :err) (:ex-message . "boom")))
            :to-be nil))

  (it "returns nil on an empty payload"
    (expect (port-completion--parse-response
             '((:tag . :ok) (:val . "")))
            :to-be nil))

  (it "passes a custom form's bare list of strings through unchanged"
    (expect (port-completion--parse-response
             '((:tag . :ok) (:val . ("map" "mapcat" "mapv"))))
            :to-equal '("map" "mapcat" "mapv")))

  (it "drops decoded-as-nil rows from the tab-delimited shape"
    ;; A row with an empty name field gets dropped by decode-row.
    (expect (port-completion--parse-response
             '((:tag . :ok)
               (:val . "map\tf\tclojure.core\n\tf\tclojure.core")))
            :to-equal
            '(((:candidate . "map") (:type . :function) (:ns . "clojure.core"))))))

(describe "port-completion cache"

  (before-each (port-completion-tests--clear))
  (after-each  (port-completion-tests--clear))

  (it "stores and reads entries by namespace"
    (port-completion--store "user" '("map" "mapcat" "filter"))
    (expect (port-completion--cached-symbols "user")
            :to-equal '("map" "mapcat" "filter")))

  (it "honours the TTL"
    (port-completion--store "user" '("map"))
    ;; Backdate the entry past the TTL.
    (puthash "user" (cons (- (float-time) 9999.0) '("map"))
             port-completion--cache)
    (let ((port-completion-cache-ttl 1.0))
      (expect (port-completion--cached-symbols "user") :to-be nil)))

  (it "returns nil for unknown namespaces"
    (expect (port-completion--cached-symbols "no.such") :to-be nil))

  (it "skips pending sentinels"
    ;; A nil-timestamp entry means a warm-up is in flight.
    (puthash "user" (cons nil nil) port-completion--cache)
    (expect (port-completion--cached-symbols "user") :to-be nil))

  (it "is bypassed when caching is disabled"
    (port-completion--store "user" '("map"))
    (let ((port-completion-use-cache nil))
      (expect (port-completion--cached-symbols "user") :to-be nil))))

(describe "port-completion-invalidate"

  (before-each (port-completion-tests--clear))
  (after-each  (port-completion-tests--clear))

  (it "drops a single namespace when given one"
    (port-completion--store "user"   '("a"))
    (port-completion--store "my.app" '("b"))
    (port-completion-invalidate "user")
    (expect (port-completion--cached-symbols "user")   :to-be nil)
    (expect (port-completion--cached-symbols "my.app") :to-equal '("b")))

  (it "clears every entry when called without an argument"
    (port-completion--store "user"   '("a"))
    (port-completion--store "my.app" '("b"))
    (port-completion-invalidate)
    (expect (hash-table-count port-completion--cache) :to-equal 0)))

(describe "port-completion--candidates filters from the cache"

  (before-each (port-completion-tests--clear))
  (after-each  (port-completion-tests--clear))

  (it "returns only entries with the typed prefix (plain strings)"
    (port-completion--store "user" '("map" "mapcat" "mapv" "filter" "reduce"))
    (cl-letf (((symbol-function 'port-session-current-ns)
               (lambda (_) "user")))
      (let ((port-default-session 'sentinel))
        (expect (port-completion--candidates "ma")
                :to-equal '("map" "mapcat" "mapv"))
        (expect (port-completion--candidates "red")
                :to-equal '("reduce")))))

  (it "filters rich alists by their :candidate field"
    (let ((rich '(((:candidate . "map") (:type . :function))
                  ((:candidate . "mapcat") (:type . :function))
                  ((:candidate . "filter") (:type . :function)))))
      (port-completion--store "user" rich)
      (cl-letf (((symbol-function 'port-session-current-ns)
                 (lambda (_) "user")))
        (let ((port-default-session 'sentinel))
          (let ((result (port-completion--candidates "ma")))
            (expect (length result) :to-equal 2)
            (expect (mapcar #'port-completion--name result)
                    :to-equal '("map" "mapcat"))))))))


(describe "port-completion-candidate-names"

  (before-each (port-completion-tests--clear))
  (after-each  (port-completion-tests--clear))

  (it "returns plain strings unchanged"
    (port-completion--store "user" '("map" "mapcat"))
    (expect (port-completion-candidate-names "user")
            :to-equal '("map" "mapcat")))

  (it "extracts :candidate from each alist in the rich shape"
    (port-completion--store "user"
                            '(((:candidate . "map") (:type . :function))
                              ((:candidate . "mapcat") (:type . :function))))
    (expect (port-completion-candidate-names "user")
            :to-equal '("map" "mapcat")))

  (it "returns nil for a cold cache"
    (expect (port-completion-candidate-names "no.such") :to-be nil)))


(describe "port-completion two-tier cache"

  (before-each (port-completion-tests--clear))
  (after-each  (port-completion-tests--clear))

  (it "is enabled by default and disabled by a custom port-completion-form"
    (expect (port-completion--two-tier-p) :to-be-truthy)
    (let ((port-completion-form "(my-dialect/complete '%s %S)"))
      (expect (port-completion--two-tier-p) :to-be nil)))

  (it "is disabled when use-core-cache or use-cache is off"
    (let ((port-completion-use-core-cache nil))
      (expect (port-completion--two-tier-p) :to-be nil))
    (let ((port-completion-use-cache nil))
      (expect (port-completion--two-tier-p) :to-be nil)))

  (it "renders the core ns list as both set and vector literals"
    (let ((port-completion-core-namespaces '("clojure.core" "clojure.string")))
      (expect (port-completion--core-set-literal)
              :to-equal "#{\"clojure.core\" \"clojure.string\"}")
      (expect (port-completion--core-vec-literal)
              :to-equal "[\"clojure.core\" \"clojure.string\"]")))

  (it "passes the core-ns set as a third argument to the local form"
    (let ((q (port-completion--query "ma" "my.ns")))
      (expect q :to-match "core-nses #{\"clojure.core\"}")
      (expect q :to-match "find-ns (quote my.ns)")
      (expect q :to-match "prefix \"ma\"")))

  (it "switches to the single-tier form when a custom form is in effect"
    (let ((port-completion-form "(my-dialect/complete '%s %S)"))
      (expect (port-completion--query "ma" "my.ns")
              :to-equal "(my-dialect/complete 'my.ns \"ma\")")))

  (it "merges locals with the core cache, locals shadowing on conflicts"
    (setq port-completion--core-cache
          '(((:candidate . "map")    (:type . :function) (:ns . "clojure.core"))
            ((:candidate . "filter") (:type . :function) (:ns . "clojure.core"))))
    (port-completion--store "my.ns"
                            '(((:candidate . "map")  (:type . :var) (:ns . "my.ns"))
                              ((:candidate . "frob") (:type . :function) (:ns . "my.ns"))))
    (let ((merged (port-completion--cached-symbols "my.ns")))
      (expect (mapcar #'port-completion--name merged)
              :to-equal '("map" "frob" "filter"))
      ;; Local `map' wins (type :var), not core's :function.
      (expect (alist-get :type (car merged)) :to-be :var)))

  (it "is a passthrough when two-tier mode is off"
    (setq port-completion--core-cache '("map" "filter"))
    (let ((port-completion-use-core-cache nil))
      (expect (port-completion--merge-with-core '("foo")) :to-equal '("foo"))))

  (it "is a passthrough when the core cache is empty"
    (expect (port-completion--merge-with-core '("foo" "bar"))
            :to-equal '("foo" "bar")))

  (it "port-completion-refresh-core clears the core cache"
    (setq port-completion--core-cache '("map" "filter"))
    (cl-letf (((symbol-function 'port-completion--warm-core) #'ignore))
      (port-completion-refresh-core))
    (expect port-completion--core-cache :to-be nil))

  (it "port-completion-invalidate leaves the core cache alone"
    (setq port-completion--core-cache '("map" "filter"))
    (port-completion--store "user" '("frob"))
    (port-completion-invalidate)
    (expect port-completion--core-cache :to-equal '("map" "filter"))
    (expect (hash-table-count port-completion--cache) :to-equal 0)))


(describe "port-completion-format-annotation"

  (it "renders ` TAG NS' when both type and ns are present"
    (expect (port-completion-format-annotation
             '((:candidate . "map") (:type . :function)
               (:ns . "clojure.core")))
            :to-equal " f clojure.core"))

  (it "drops the ns when absent"
    (expect (port-completion-format-annotation
             '((:candidate . "map") (:type . :function)))
            :to-equal " f"))

  (it "uses the right tag for each Compliment kind"
    (expect (port-completion-format-annotation
             '((:candidate . "when") (:type . :macro)))
            :to-equal " m")
    (expect (port-completion-format-annotation
             '((:candidate . "String") (:type . :class)))
            :to-equal " c")
    (expect (port-completion-format-annotation
             '((:candidate . "size") (:type . :static-method)))
            :to-equal " sm"))

  (it "returns nil when no metadata is usable"
    (expect (port-completion-format-annotation
             '((:candidate . "raw")))
            :to-be nil)))


(describe "port-completion-at-point capf result"

  (before-each (port-completion-tests--clear))
  (after-each  (port-completion-tests--clear))

  (it "returns names + an annotation-function for rich candidates"
    (let ((rich '(((:candidate . "map") (:type . :function)
                   (:ns . "clojure.core"))
                  ((:candidate . "mapcat") (:type . :function)
                   (:ns . "clojure.core")))))
      (port-completion--store "user" rich)
      (cl-letf (((symbol-function 'port-session-current-ns)
                 (lambda (_) "user"))
                ((symbol-function 'bounds-of-thing-at-point)
                 (lambda (_) (cons 1 4))))
        (with-temp-buffer
          (insert "map")
          (let ((port-default-session 'sentinel))
            (let* ((capf (port-completion-at-point))
                   (cands  (nth 2 capf))
                   (props  (nthcdr 3 capf))
                   (annot  (plist-get props :annotation-function)))
              (expect cands :to-equal '("map" "mapcat"))
              (expect (functionp annot) :to-be-truthy)
              (expect (funcall annot "map") :to-equal " f clojure.core")
              (expect (funcall annot "mapcat") :to-equal " f clojure.core")))))))

  (it "omits :annotation-function for legacy string candidates"
    (port-completion--store "user" '("map" "mapcat"))
    (cl-letf (((symbol-function 'port-session-current-ns)
               (lambda (_) "user"))
              ((symbol-function 'bounds-of-thing-at-point)
               (lambda (_) (cons 1 4))))
      (with-temp-buffer
        (insert "map")
        (let ((port-default-session 'sentinel))
          (let* ((capf (port-completion-at-point))
                 (props (nthcdr 3 capf)))
            (expect (plist-get props :annotation-function)
                    :to-be nil)))))))

(provide 'port-completion-tests)

;;; port-completion-tests.el ends here

(ns ewen.replique.spec-tooling
  (:refer-clojure :exclude [+ * and assert or cat def keys merge])
  (:require [clojure.spec :as s]
            [ewen.replique.replique-conf :as conf]
            [clojure.pprint :refer [pprint pp]]
            [clojure.walk :as walk]))

(alias 'c 'clojure.core)

(declare candidates)
(declare from-spec)
(declare map-spec-impl)
(declare multi-spec-impl)

(defprotocol Complete
  (candidates* [spec context prefix]))

(extend-protocol Complete
  clojure.lang.Var
  (candidates* [v context prefix]
    @v))

(extend-protocol Complete
  clojure.spec.Spec
  (candidates* [spec context prefix]
    (candidates (from-spec spec) context prefix)))

(extend-protocol Complete
  clojure.lang.Keyword
  (candidates* [k context prefix]
    (when-let [spec (s/get-spec k)]
      (candidates (from-spec spec) context prefix))))

(defn set-candidates [s context prefix]
  (when (c/nil? context)
    (->> (filter #(.startsWith (str %) prefix) s)
         (into #{}))))

(extend-protocol Complete
  clojure.lang.IFn
  (candidates* [f context prefix]
    (if (instance? clojure.lang.IPersistentSet f)
      (set-candidates f context prefix)
      f)))

(defn complete? [x]
  (when (instance? ewen.replique.spec_tooling.Complete x) x))

(defn from-cat [preds]
  {::s/op ::s/pcat :ps (mapv from-spec preds)})

(defn from-alt [preds]
  {::s/op ::s/alt :ps (mapv from-spec preds)})

(defn from-rep [pred]
  (let [p1 (from-spec pred)]
    {::s/op ::s/rep :p1 p1 :p2 p1}))

(defn from-amp [pred preds]
  {::s/op ::s/amp :p1 (from-spec pred)})

(defn from-keys [keys-seq]
  (-> (apply hash-map keys-seq)
      map-spec-impl))

(defn from-multi [mm]
  (multi-spec-impl (resolve mm)))

(defn from-every [pred]
  )

;; Form is a spec OR form is a qualified symbol and can be resolved to a var OR form is something
;; that get evaled in order to get the values than the ones from core.spec spec impls.
;; Qualified symbols are not evaled in order to customize the candidates* behavior for vars
;; It is resolved to a var and not kept as a symbol, otherwise reg-resolve would try to resolve
;; it to a spec
(defn from-spec [spec]
  (when spec
    (cond
      (s/regex? spec) (case (::s/op spec)
                        ::s/pcat (from-cat (:forms spec))
                        ::s/alt (from-alt (:forms spec))
                        ::s/rep (from-rep (:forms spec))
                        ::s/amp (from-amp (:p1 spec) (:forms spec)))
      (s/spec? spec)
      (let [form (s/form spec)
            [spec-sym & spec-rest] form]
        (cond (= 'clojure.spec/keys spec-sym)
              (from-keys spec-rest)
              (= 'clojure.spec/multi-spec spec-sym)
              (from-multi (first spec-rest))
              (= 'clojure.spec/every spec-sym)
              (from-every (first spec-rest))
              :else (eval form)))
      (c/and (symbol? spec) (namespace spec) (var? (resolve spec)))
      (resolve spec)
      (seq? spec)
      (recur (eval spec))
      :else (eval spec))))

(defprotocol Specize
  (specize* [_] [_ form]))

(declare regex-spec-impl)

(defn- reg-resolve [k]
  (if (ident? k)
    (let [reg @@#'s/registry-ref
          spec (get reg k)]
      (when spec
        (if-not (ident? spec)
          (from-spec spec)
          (-> (#'s/deep-resolve reg spec) from-spec))))
    k))

(defn- reg-resolve! [k]
  (if (ident? k)
    (c/or (reg-resolve k)
          (throw (Exception. (str "Unable to resolve spec: " k))))
    k))

(defn- and-all [preds x]
  (loop [[p & ps] preds]
    (cond (nil? p) true
          (p x) (recur ps)
          :else false)))

(defn- accept-nil? [p]
  (let [{:keys [::s/op ps p1 p2] :as p} (reg-resolve! p)]
    (case op
      nil nil
      ::s/accept true
      ::s/amp (accept-nil? p1)
      ::s/rep (c/or (identical? p1 p2) (accept-nil? p1))
      ::s/pcat (every? accept-nil? ps)
      ::s/alt (c/some accept-nil? ps))))

(defn- dt [pred x]
  (if pred
    (if-let [spec (#'s/the-spec pred)]
      (if (s/valid? spec x)
        {::s/op ::s/accept}
        ::s/invalid)
      (if (ifn? pred)
        (if (pred x) {::s/op ::s/accept} ::s/invalid)
        ::s/invalid))
    {::s/op ::s/accept}))

(defn- accept? [{:keys [::s/op]}]
  (= ::s/accept op))

(defn- pcat* [{[p1 & pr :as ps] :ps ret :ret}]
  (when (every? identity ps)
    (if (accept? p1)
      (if pr
        {::s/op ::s/pcat :ps pr :ret (:ret p1)}
        {::s/op ::s/accept :ret (:ret p1)})
      {::s/op ::s/pcat :ps ps :ret (:ret p1)})))

(defn ret-union [ps]
  (apply clojure.set/union (map :ret ps)))

(defn- alt* [ps]
  (let [[p1 & pr :as ps] (filter identity ps)]
    (when ps
      (let [ret {::s/op ::s/alt :ps ps}]
        (if (nil? pr)
          (if (accept? p1)
            {::s/op ::s/accept :ret (:ret p1)}
            ret)
          (assoc ret :ret (ret-union ps)))))))

(defn- alt2 [p1 p2]
  (if (c/and p1 p2)
    {::s/op ::s/alt :ps [p1 p2] :ret (clojure.set/union (:ret p1) (:ret p2))}
    (c/or p1 p2)))

(defn- rep* [p1 p2]
  (when p1
    (let [r {::s/op ::s/rep :p2 p2}]
      (if (accept? p1)
        (assoc r :p1 p2 :ret (:ret p1))
        (assoc r :p1 p1 :ret (:ret p1))))))

(defn- deriv [p x at-point?]
  (let [{[p0 & pr :as ps] :ps :keys [::s/op p1 p2] :as p} (reg-resolve! p)]
    (when p
      (case op
        nil (if at-point?
              {::s/op ::s/accept :ret #{p}}
              (let [ret (dt p x)]
                (when-not (s/invalid? ret) ret)))
        ::s/amp (deriv p1 x at-point?)
        ::s/pcat (alt2
                  (pcat* {:ps (cons (deriv p0 x at-point?) pr)})
                  (when (accept-nil? p0) (deriv (pcat* {:ps pr}) x at-point?)))
        ::s/alt (alt* (map #(deriv % x at-point?) ps))
        ::s/rep (alt2 (rep* (deriv p1 x at-point?) p2)
                      (when (accept-nil? p1)
                        (deriv (rep* p2 p2) x at-point?)))))))

(defn- re-candidates [p [{:keys [idx form]} & cs :as context] prefix deriv-idx]
  (if (> deriv-idx idx)
    (->> (:ret p)
         (map #(candidates % cs prefix))
         (apply clojure.set/union))
    (if-let [dp (deriv p (nth form deriv-idx) (= idx deriv-idx))]
      (recur dp context prefix (inc deriv-idx))
      nil)))

(defn regex-spec-impl [re]
  (reify
    Specize
    (specize* [s] s)
    Complete
    (candidates* [_ [{:keys [idx form]} & _ :as context] prefix]
      (when (coll? form)
        (re-candidates re context prefix 0)))))

(defn spec-impl [pred]
  (cond
    (s/regex? pred) (regex-spec-impl pred)
    :else
    (reify
      Specize
      (specize* [s] s)
      Complete
      (candidates* [_ context prefix]
        (let [ret (candidates* pred context prefix)]
          (when (set? ret) ret))))))

(defn map-spec-impl [{:keys [req-un opt-un req opt]}]
  (let [req-un->req (zipmap (map (comp keyword name) req-un) req-un)
        opt-un->opt (zipmap (map (comp keyword name) opt-un) opt-un)
        unqualified->qualified (c/merge req-un->req opt-un->opt)]
    (reify
      Specize
      (specize* [s] s)
      Complete
      (candidates* [_ [{:keys [idx map-role form]} & cs :as context] prefix]
        (when (map? form)
          (case map-role
            :value (when-let [spec (s/get-spec (c/or (get unqualified->qualified idx) idx))]
                     (candidates spec cs prefix))
            :key (candidates* (into #{} (concat (c/keys unqualified->qualified) req opt))
                              nil prefix)))))))

(defn multi-spec-impl [mm]
  (reify
    Specize
    (specize* [s] s)
    Complete
    (candidates* [_ [{:keys [form]} & cs :as context] prefix]
      (let [spec (try (mm form)
                      (catch IllegalArgumentException e nil))
            specs (if spec #{spec} (->> (vals (methods @mm))
                                        (map (fn [spec-fn] (spec-fn nil)) )
                                        (into #{})))]
        (->> (map #(candidates % context prefix) specs)
             (apply clojure.set/union))))))

(defn every-impl []
  )

(extend-protocol Specize
  clojure.lang.Keyword
  (specize* [k] (specize* (reg-resolve! k)))

  clojure.lang.Symbol
  (specize* [s] (specize* (reg-resolve! s)))

  clojure.lang.IFn
  (specize* [ifn] (spec-impl (from-spec ifn)))

  clojure.spec.Spec
  (specize* [spec] (from-spec spec))
  )

(defn candidates [spec context prefix]
  (when (satisfies? Specize spec)
    (candidates* (specize* spec) context prefix)))





(comment
  (require '[ewen.replique.replique-conf :as conf])

  (candidates "" '({:idx nil, :map-role :key, :form {__prefix__ nil}}) "eee")
  
  )

(comment

  ;; Regexps
  (s/def ::rr string?)
  (s/def ::ss #{11111 222222})
  
  (candidates (s/cat :a (s/cat :b #{22} :c #{1111 2})
                     :d (s/cat :e #{33} :f #{44}))
              '({:idx 1 :form [22 __prefix__ __prefix__]})
              "11")

  (candidates (s/cat :a (s/alt :b (s/cat :c #{1 2} :d #{3 4}) :e #{5 6})
                     :f (s/* #{1111})
                     :g (s/& #{2222} string?)
                     :h #{11})
              '({:idx 3, :form [6 1111 1111 __prefix__]})
              "22")

  (candidates (s/& (s/cat :e #{11111 "eeeeeeee"}) string? string?)
              '({:idx 0, :form [__prefix__]})
              "eeee")



  
  (candidates (s/keys :req [::ss])
              '({:idx ::ss :map-role :value :form {::ss __prefix__}})
              "11")

  (candidates (s/keys :req [::ss])
              '({:idx nil :map-role :key :form {__prefix__ nil}})
              ":ewen")

  (candidates (s/keys :req-un [::ss])
              '({:idx nil :map-role :key :form {__prefix__ nil}})
              ":s")



  ;; multi spec

  #_(candidates ::conf/cljs-env
              '({:idx nil :map-role :key :form {__prefix__ nil}})
              ":ewen")

  (defmulti test-mm :mm)
  (defmethod test-mm 33 [_]
    (s/keys :req-un [::ss]))
  (candidates (s/multi-spec test-mm :mm)
              '({:idx nil :map-role :key :form {:ss 33
                                                __prefix__ nil}})
              ":s")
  (candidates (s/multi-spec test-mm :ss)
              '({:idx :ss :map-role :value :form {:mm 33
                                                  :ss __prefix__}})
              "11")

  (s/conform (s/and (s/* string?) #(even? (count %))) ["e"])

  (s/conform (s/cat :a (s/& (s/alt :b #{"1" "2"} :c #{3 4}) (fn [x] (string? (second x))))) ["2"])

  (candidates (s/cat :a (s/cat :b #{11111 22222} :c #{33333 44444})
                     :d (s/cat :e #{55555 66666} :f #{77777 88888}))
              '({:idx 1, :form [nil __prefix__]})
              "7777")
  )


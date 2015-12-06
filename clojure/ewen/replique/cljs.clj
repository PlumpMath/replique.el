(ns ewen.replique.cljs
  (:require [cljs.env :as env]
            [cljs.repl :refer [repl-caught repl-quit-prompt repl-read
                               repl-prompt -repl-options read-source-map
                               *cljs-verbose* *repl-opts*
                               default-special-fns -setup evaluate-form
                               analyze-source err-out -tear-down]]
            [cljs.repl.server]
            [cljs.repl.browser]
            [cljs.closure :as cljsc]
            [clojure.tools.reader.reader-types :as readers]
            [clojure.tools.reader :as reader]
            [clojure.java.io :as io]
            [cljs.analyzer :as ana]
            [cljs.compiler :as comp]
            [cljs.tagged-literals :as tags]
            [cljs.util :as util]
            [clojure.string :as str]
            [clojure.data.json :as json])
  (:import [java.io File PushbackReader FileWriter PrintWriter]
           [java.net URI]))

;;Force :simple compilation optimization mode in order to compile to a
;;single file. With optimization :none, the REPL does not seem to work.
(alter-var-root
 #'cljs.repl.browser/compile-client-js
 (constantly
  (fn [opts]
    (let [optimizations (if (= (:optimizations opts) :none)
                          :simple
                          (:optimizations opts))
          copts {:optimizations optimizations
                 :output-dir (:working-dir opts)}]
      ;; we're inside the REPL process where cljs.env/*compiler* is already
      ;; established, need to construct a new one to avoid mutating the one
      ;; the REPL uses
      (cljsc/build
       '[(ns clojure.browser.repl.client
           (:require [goog.events :as event]
                     [clojure.browser.repl :as repl]))
         (defn start [url]
           (event/listen js/window
                         "load"
                         (fn []
                           (repl/start-evaluator url))))]
       copts (env/default-compiler-env copts))))))

(defn compute-asset-path [asset-path output-dir rel-path]
  (let [asset-path (if asset-path (str "\"" asset-path "\"") "null")
        output-dir (if output-dir (str "\"" output-dir "\"") "null")
        rel-path (if rel-path (str "\"" rel-path "\"") "null")]
    (str "(function(assetPath, outputDir, relPath) {
          if(assetPath) {
            return assetPath;
          }
          var computedAssetPath = assetPath? assetPath : outputDir;
          if(!outputDir ||  !relPath) {
            return computedAssetpath;
          }
          var endsWith = function(str, suffix) {
            return str.indexOf(suffix, str.length - suffix.length) !== -1;
          }
          var origin = window.location.protocol + \"//\" + window.location.hostname + (window.location.port ? ':' + window.location.port: '');
          var scripts = document.getElementsByTagName(\"script\");
          for(var i = 0; i < scripts.length; ++i) {
            var src = scripts[i].src;
            if(src && endsWith(src, relPath)) {
              var relPathIndex = src.indexOf(relPath);
              var originIndex = src.indexOf(origin);
              if(originIndex === 0) {
                return src.substring(origin.length+1, relPathIndex);
              }
            }
          }
          return computedAssetPath;
        })(" asset-path ", " output-dir ", " rel-path ");\n")))


;;Patch cljs.closure/output-main-file in order to:
;; - Avoid the need to provide an :asset-path option. :asset-path is
;; computed from the :main namespaces. When using a node.js env,
;; :output-dir is used instead of :asset-path
;; - Allow multiple :main namespaces. This permits leaving HTML markup
;; identical between dev and production when using google closure modules.
(alter-var-root
 #'cljsc/output-main-file
 (constantly
  (fn output-main-file [opts]
    (let [closure-defines (json/write-str (:closure-defines opts))
          main-requires (->> (for [m (:main opts)]
                               (str "goog.require(\""
                                    (comp/munge m)
                                    "\"); "))
                             (apply str))]
      (case (:target opts)
        :nodejs
        (let [asset-path (or (:asset-path opts)
                              (util/output-directory opts))]
          (cljsc/output-one-file
           opts
           (cljsc/add-header
            opts
            (str
             "var path = require(\"path\");\n"
             "try {\n"
             "    require(\"source-map-support\").install();\n"
             "} catch(err) {\n"
             "}\n"
             "require(path.join(path.resolve(\".\"),\"" asset-path "\",\"goog\",\"bootstrap\",\"nodejs.js\"));\n"
             "require(path.join(path.resolve(\".\"),\"" asset-path "\",\"cljs_deps.js\"));\n"
             "goog.global.CLOSURE_UNCOMPILED_DEFINES = " closure-defines ";\n"
             "goog.require(\"cljs.nodejscli\");\n"
             main-requires))))
        (let [output-dir-uri (-> (:output-dir opts) (File.) (.toURI))
              output-to-uri (-> (:output-to opts) (File.) (.toURI))
              output-dir-path (-> (.normalize output-dir-uri)
                                  (.toString))
              output-to-path (-> (.normalize output-to-uri)
                                 (.toString))
              ;; If output-dir is not a parent dir of output-to, then
              ;; we don't try to infer the asset path because it may not
              ;; be possible.
              rel-path (if (and (.startsWith output-to-path
                                             output-dir-path)
                                (not= output-dir-path output-to-path))
                         (-> (.relativize output-dir-uri output-to-uri)
                             (.toString))
                         nil)]
          (cljsc/output-one-file
           opts
           (str "(function() {\n"
                "var assetPath = " (compute-asset-path (:asset-path opts) (util/output-directory opts) rel-path)
                "var CLOSURE_UNCOMPILED_DEFINES = " closure-defines ";\n"
                "if(typeof goog == \"undefined\") document.write('<script src=\"'+ assetPath +'/goog/base.js\"></script>');\n"
                "document.write('<script src=\"'+ assetPath +'/cljs_deps.js\"></script>');\n"
                "document.write('<script>if (typeof goog != \"undefined\") {" main-requires "} else { console.warn(\"ClojureScript could not load :main, did you forget to specify :asset-path?\"); };</script>');\n"
                "})();\n"))))))))

# Replique

An emacs mode for [Replique](https://github.com/EwenG/replique). Replique is a development environment for Clojure and Clojurescript implemented as a leiningen plugin.

## Table of contents

- [Installation](#installation)
- [Optional configuration](#optional-configuration)
- [Features](#features)
- [Getting started](#getting-started)
- [Using multiple REPL sessions](#using-multiple-repl-sessions)
- [Clojurescript support](#clojurescript-support)
- [Javascript files reloading](#javascript-files-reloading)
- [CSS files reloading](#css-files-reloading)
- [Using a CSS preprocessor](#using-a-css-preprocessor)
- [Org-mode integration](#using-replique-with-org-mode)
- [Leiningen configuration](#leiningen-configuration)
- [Remote REPL](#remote-repl)
- [Using the standard output](#using-the-standard-output)
- [Default keymap](#default-keymap)

## Installation

Replique is compatible with clojure 1.8.0+, clojurescript 1.8.40+ and requires emacs 25+.

### Emacs mode

Add Replique to your emacs package archives

```elisp
(add-to-list 'package-archives '("replique" . "https://raw.githubusercontent.com/EwenG/replique.el/master/packages/") t)
```

Install Replique

```elisp
(unless (package-installed-p 'replique)
    (package-refresh-contents)
  (package-install 'replique))
```

Load replique

`(require 'replique)`

Enable Replique when editing clojure files

`(add-hook 'clojure-mode-hook 'replique/minor-mode)`

### Leiningen

Download the [leiningen script](http://leiningen.org/). Either place the lein script in emacs `exec-path` or customize the `replique/lein-script` variable, for example

`(setq replique/lein-script "~/bin/lein")`

## Optional configuration

Auto completion is supported through [company-mode](https://github.com/company-mode/company-mode).

Enable company-mode either globally or locally

`(add-hook 'after-init-hook 'global-company-mode)`

Or

```elisp
(add-hook 'clojure-mode-hook
	  (lambda ()
	    (company-mode 1)))
```

```elisp
(add-hook 'replique/mode-hook
	  (lambda ()
	    (company-mode 1)))
```

Enable [css files reloading](#css-files-reloading)

`(add-hook 'css-mode-hook 'replique/minor-mode)`

Enable [stylus files reloading](#stylus-files-reloading)

`(add-hook 'stylus-mode-hook 'replique/minor-mode)`

Enable [less files reloading](#less-files-reloading)

`(add-hook 'less-css-mode-hook 'replique/minor-mode)`

Enable [sass or scss files reloading](#sassscss-files-reloading)

`(add-hook 'sass-mode-hook 'replique/minor-mode)`

Enable [javascript files reloading](#javascript-files-reloading)

`(add-hook 'js-mode-hook 'replique/minor-mode)`

Enable [code evaluation in org-mode](#using-replique-with-org-mode)

```elisp
(add-hook 'org-mode-hook
          (lambda ()
            (require 'ob-replique))
```

## Features

- Clojure and Clojurescript REPL, one or multiple sessions
- Preconfigured Clojurescript compiler for development builds
- Autocompletion
- Jump to symbol definition
- [Eldoc](https://www.emacswiki.org/emacs/ElDoc) style documentation
- CSS files reloading
- [Stylus](http://stylus-lang.com/), [less](http://lesscss.org/), [sass](http://sass-lang.com/) file reloading
- Javascript file reloading
- Org-mode integration

Replique tries, as much as possible, to keep features parity between Clojure and Clojurescript.

## Getting started

### Clojure REPL

`M-x replique/repl`

Replique will prompt you for a project directory and a port number. The project directory must contain a leiningen `project.clj` file. Replique will start a socket REPL using the provided port number. Use `0` to start the REPL on a random port number.

Use `C-x C-e` to evaluate a Clojure form, `C-c C-l` to load a Clojure file in the REPL and `C-c M-n` to change the REPL namespace.

Kill the buffer to close the REPL.

### Clojurescript REPL

Add Clojurescript to your *project.clj* dependencies

`[org.clojure/clojurescript VERSION_NUMBER]`

Start a Clojure REPL

`M-x replique/repl`

Start a Clojurescript REPL in your Clojure REPL

`M-x replique/cljs-repl` or, at the REPL `(replique.interactive/cljs-repl)`

Connect a browser to the cljs REPL

`M-x replique/browser`

Use `C-x C-e` to evaluate a Clojurescript form, `C-c C-l` to load a Clojurescript file in the REPL and `C-c M-n` to change the REPL namespace.

Kill the buffer to close the REPL.

### Going further

See the [default keymap](#default-keymap), the [interactive commands](#interactive-commands) and the [REPL API](#repl-api).

## Using multiple REPL sessions

To start multiple REPL sessions in the same JVM process, use `M-x replique/repl` multiple times, using the same directory. Replique will keep at most one Clojure REPL and one Clojurescript REPL active at the same time. Use `M-x replique/switch-active-repl` to change the currently active REPL.

Multiple JVM processes can be started simultaneously for different projects by using different directories when starting the REPLs. Use `replique/switch-active-process` to change the currently active process. Symbolic links can be used to start multiple JVM processes simultaneously for the same project.

Use `replique/close-process` to close all the REPL sessions associated with a JVM process at the same time.

## Clojurescript support

Replique supports autocompletion, [Eldoc](https://www.emacswiki.org/emacs/ElDoc) style documentation, and jump to definition for Clojurescript with the limitation that autocompletion does not work for interop calls.

Loading a cljs file is done by compiling it to disk and then loading it in the Clojurescript environment. By default, Replique compiles Clojurescript files in the `target/cljs` folder. The compilation output folder can be customized using the `project.clj` file:

`{:replique {:cljs-compile-path "%s/cljs"}}`

Including `%s` will splice the `:target-path` into this value.

Clojurescript can only be evaluated in the browser. Others javascript environments are not currently supported.

There are two kinds of workflows when using a browser REPL. The first one is when you want to evaluate Clojurescript code but don't want to bother with the setup of an HTTP server. The second one is when you already use an HTTP server and want to transparently use a Clojurescript REPL to develop a web application. The two worflows are covered below.

### Clojurescript browser REPL

Replique listens on the REPL port for a connection from a javascript runtime. Replique currently only supports connections from web browsers. Call `(replique.interactive/repl-port)` to know the port the REPL is listening on. Use `M-x replique/browser` to connect a web browser to the cljs REPL, or simply browse `http://localhost:port`.

### Using the REPL to build a web application

When developing a web application, the flow is slightly different than the one described above. See [replique-pedestal](https://github.com/EwenG/replique-pedestal) for a detailed example of using replique with a pedestal web application.

The first thing you will need to do is to emit a javascript file that will be the entry point of your application. This file is the one you must include in your HTML markup. The command `M-x replique/output-main-js-file` emits such a file. This javascript file also contains code to connect to the cljs REPL. This allows connecting to a cljs REPL in the context of a web application. The web application needs not be aware of the cljs REPL and your HTML markup needs not be different between development and production builds. This is equivalent to using the [`:main` option](https://github.com/clojure/clojurescript/wiki/Compiler-Options#main) of the cljs compiler.

`M-x replique/output-main-js-file` prompts for the output path of the main js file. If a cljs REPL is started, `M-x replique/output-main-js-file` also prompts for a cljs namespace. This namespace is the the entry point of your application.

Nothing prevents you from using multiple main js files. Outputting multiple main js files is particularly useful when using [Google closure modules](https://github.com/clojure/clojurescript/wiki/Compiler-Options#modules), to keep HTML markup identical between dev and production.

### Cljc support

Loading `.cljc` files (see [reader conditionals](http://clojure.org/guides/reader_conditionals)) requires both a Clojure and a Clojurescript REPL to be started. Replique will load `.cljc` files simultaneously in the Clojure and the Clojurescipt REPL. Autocompletion candidates (and other tooling features) for `.cljc` files are computed using the Clojure runtime, unless the cursor is in a `#?cljs` reader conditional, in which case it will be computed using the Clojurescript runtime.

### Clojurescript compiler configuration

The Clojurescript compiler is preconfigured for development builds (optimizations at :none, sourcemaps enabled ...). A subset of the compiler options and REPL options can be updated at the REPL (see [the Clojurescript wiki](https://github.com/clojure/clojurescript/wiki) for a description of the options).

- To update the *:repl-verbose* REPL options, **from a cljs REPL**: `(replique.interactive/set-cljs-repl-verbose true)`. Note that `set-cljs-repl-verbose` is a macro.
- To update one of *#{:verbose :warnings :compiler-stats :language-in :language-out :closure-warnings}* compiler options, **from a clj REPL**: `(replique.interactive/set-cljs-compiler-opt :verbose true)`

Replique only manages development builds. For production builds, I would recommend using a custom script, a lein plugin (such as [lein-cljsbuild](https://github.com/emezeske/lein-cljsbuild)) or any other existing solution.

### Using external javascript libraries

Replique does not expose the Clojurescript compiler options related to using javascript libraries ([:foreign-libs](https://github.com/clojure/clojurescript/wiki/Compiler-Options#foreign-libs) and [:libs](https://github.com/clojure/clojurescript/wiki/Compiler-Options#libs)). The recommended way to deal with external libraries when using Replique is to use [cljsjs](https://github.com/clojure/clojurescript/wiki/Dependencies#cljsjs).

### Other considerations when using the browser REPL

The main javascript files emitted using the `replique/output-main-js-file` command internally uses the port number of the Replique REPL. If the port number changes across REPL session, the main javascript files must be updated accordingly. Fortunately, Replique handles this for you and updates all main javascript files found in the project directory on REPL startup.

Replique internally serves javascript files on a different domain than your web server, using cross domain requests. As a consequence, your web server must allow cross domain requests to be performed during development. In particular, the [content security policy](https://www.owasp.org/index.php/OWASP_Secure_Headers_Project#Content-Security-Policy) HTTP headers must not be set to forbid these. Of course, this does not affects production environments.

## Javascript files reloading

Replique supports reloading javascript files from the cljs REPL

### Emacs setup

`(add-hook 'js-mode-hook 'replique/minor-mode)`

From a javascript file: `M-x replique/load-file` or `C-c C-l`

## CSS files reloading

Replique supports reloading css file from the cljs REPL

#### Emacs setup

`(add-hook 'css-mode-hook 'replique/minor-mode)`

From a css file: `M-x replique/load-file` or `C-c C-l`

Replique will search in the currently loaded web page for a css file with the same name than the file being reloaded. If found, this file is refreshed. If multiple files are found, Replique will prompt you for the right one and remember your choice.

## Using a CSS preprocessor

### Reloading stylus/less/sass files

Stylus/less/sass files are organized into a files hierarchy. Files reference one another using `import` statements. Replique always recompiles the whole file hierarchy, starting at the root file. The only requirement is that the first compilation must be triggered from the file at the root of the hierarchy.

Here are the instructions to setup Replique for different CSS preprocessors.

### Stylus

Replique supports reloading stylus files from the cljs REPL. Stylus must be installed and the `stylus` executable must be in the emacs `exec-path`.

The stylus command can be customized:

`(setq replique/stylus-executable "stylus")`

The arguments used to compile stylus files can be customized with a function taking the input file and output path as parameters. The function returns the list of parameters passed to the stylus command:

`(setq replique/stylus-args-builder 'replique/stylus-args-builder-default)`

Setup emacs to recognize stylus files:

`(add-hook 'stylus-mode-hook 'replique/minor-mode)`

### Less

Replique supports reloading less files from the cljs REPL. Less must be installed and the `lessc` executable must be in the emacs `exec-path`.

The lessc command can be customized:

`(setq replique/less-executable "lessc")`

The arguments used to compile less files can be customized with a function taking the input file and output path as parameters. The function returns the list of parameters passed to the stylus command:

`(setq replique/less-args-builder 'replique/less-args-builder-default)`

Setup emacs to recognize less files:

`(add-hook 'less-css-mode-hook 'replique/minor-mode)`

### Sass/scss

Replique supports reloading sass or scss files from the cljs REPL. Sass must be installed and the `sass` or `scss` executable must be in the emacs `exec-path`.

The sass and scss commands can be customized:

`(setq replique/sass-executable "sass")`

Or

`(setq replique/scss-executable "scss")`

The arguments used to compile sass or scss files can be customized with a function taking the input file and output path as parameters. The function returns the list of parameters passed to the sass or scss command:

`(setq replique/sass-args-builder 'replique/sass-args-builder-default)`

Or

`(setq replique/scss-args-builder 'replique/scss-args-builder-default)`

Setup emacs to recognize sass/scss files:

`(add-hook 'sass-mode-hook 'replique/minor-mode)`

## Using Replique with [org-mode](http://orgmode.org/manual/Evaluating-code-blocks.html)

### Emacs setup

```elisp
(add-hook 'org-mode-hook
          (lambda ()
            (require 'ob-replique))
```

Clojure code blocks

```
#+begin_src clojure
  (+ 1 2)
#+end_src

#+RESULTS:
: 3
```

Clojurescript code blocks

```
#+begin_src clojurescript
  (+ 1 2)
#+end_src

#+RESULTS:
: 3
```

## Leiningen configuration

Replique does not support all Leiningen configuration keys. In particular, since Replique is not based on [nrepl](https://github.com/clojure/tools.nrepl), none of the keys related to nrepl are supported.

The *:global-vars* leiningen key is supported and the following vars values are propagated to the cljs REPL: `#{#'*assert* #'*print-length* #'*print-meta* #'*print-level* #'*flush-on-newline* #'*print-readably* #'*print-dup*})`

## Remote REPL

Replique supports connecting to a remote REPL by nesting a REPL inside another. `(replique.interactive/remote-repl host port)` will start a REPL on the server at *host:port*, assuming the server is running a [socket REPL server](http://clojure.org/reference/repl_and_main#_launching_a_socket_server).

## Using the standard output

All Clojure and Clojurescript REPL output is printed in the [comint](https://www.emacswiki.org/emacs/ComintMode) buffer associated with the REPL. Data printed to the standard output of the JVM process is displayed in the emacs \*Messages* buffer. Data can be printed to the standard output of the JVM process by binding \*out* to `replique.interactive/process-out`.

### Uncaught exceptions

Replique registers a default exception handler that prints all uncaught exceptions in the emacs \*Messages* buffer. To override the default exception handler:

```clojure
(Thread/setDefaultUncaughtExceptionHandler
     (reify Thread$UncaughtExceptionHandler
       (uncaughtException [_ thread ex]
       ;; Do what you want here
       )))
```

## Default keymap

Keybinding           | Description
---------------------|----------------------------------
<kbd>C-c C-r</kbd>   | Evaluate region
<kbd>C-x C-e</kbd>   | Evaluate last sexp
<kbd>C-M-x</kbd>     | Evaluate top level sexp
<kbd>C-c C-l</kbd>   | Load file
<kbd>C-c M-n</kbd>   | Change namespace
<kbd>M-.</kbd>       | Jump to symbol definition
<kbd>C-x r</kbd>     | Change active REPL session

## Interactive commands

Command                          | Description
---------------------------------|----------------------------------
`replique/repl`                  | Start a REPL
`replique/cljs-repl`             | Start a cljs REPL in a clj REPL
`replique/browser`               | Open a browser tab on the REPL port
`replique/switch-active-repl`    | Change the active REPL session
`replique/switch-active-process` | Change the active JVM process
`replique/close-process`         | Close all processes associated with a JVM process
`replique/output-main-js-file`   | Write a main js file to disk

## REPL API

All REPL functions/macros are in the `replique.interactive` namespace

Function/macro                   | Description
---------------------------------|----------------------------------
                                 |

## Acknowledgments

Replique.el takes inspiration from and uses parts of [cider](https://github.com/clojure-emacs/cider). I would like to thank cider authors/contributors.

# License

Copyright 2016 Ewen Grosjean.

Distributed under the GNU General Public License, version 3.

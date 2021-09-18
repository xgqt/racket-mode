#lang racket/base

;; Note that racket/gui/dynamic is in `base` package --- requiring it
;; does NOT create a dependency on the `gui-lib` package.
(require racket/gui/dynamic)

(provide txt/gui
         make-initial-repl-namespace)

;; Avoid "racket/gui/base cannot be instantiated more than once per
;; process" errors.
;;
;; Attempt to instantiate racket/gui/base in our namespace and under
;; our main custodian (as opposed to those for each user program run).
;;
;; Handle/ignore any exceptions. Some possibilities:
;;
;; - exn:fail:filesystem:missing-module? because gui-lib is not
;;   installed, as with e.g. minimal Racket. That's fine. Don't show
;;   any error message.
;;
;; - exn:fail? because some other problem. Do show error message for
;;   user. A possible situation is that gui-lib is installed on a
;;   headless system, and therefore e.g. gui-lib errors "Gtk
;;   initialization failed for display :0". Our process will be in a
;;   state where gui-available? is #f but racket/gui/base has already
;;   been instantiated. That's not a good state, but, continue anyway.
;;   It should be OK provided user programs don't actually use
;;   racket/gui/base.

(with-handlers ([exn:fail:filesystem:missing-module? void]
                [exn:fail? (λ (exn)
                             (displayln (exn-message exn)
                                        (current-error-port)))])
  (dynamic-require 'racket/gui/base #f))

(define-namespace-anchor anchor)
(define namespace-here (namespace-anchor->namespace anchor))

(define (make-initial-repl-namespace)
  (define new-base-namespace (make-base-namespace))
  (when (parameterize ([current-namespace namespace-here])
          (module-declared? 'racket/gui/base))
    (namespace-attach-module namespace-here
                             'racket/gui/base
                             new-base-namespace))
  new-base-namespace)

;; #301: On Windows, show then hide an initial frame.
(when (and (gui-available?)
           (eq? (system-type) 'windows))
  (define make-object (dynamic-require 'racket/class 'make-object))
  (define frame% (dynamic-require 'racket/gui/base 'frame%))
  (define f (make-object frame% "Emacs Racket Mode initialization" #f 100 100))
  (define dynamic-send (dynamic-require 'racket/class 'dynamic-send))
  (dynamic-send f 'show #t)
  (dynamic-send f 'show #f))

;; Like mz/mr from racket/sandbox.
(define-syntax txt/gui
  (syntax-rules ()
    [(_ txtval guisym)
     (if (gui-available?)
         (dynamic-require 'racket/gui/base 'guisym)
         txtval)]))

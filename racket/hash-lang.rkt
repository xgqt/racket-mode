#lang racket/base

(require (only-in data/interval-map
                  make-interval-map
                  interval-map-set!
                  interval-map-ref
                  interval-map-ref/bounds ;added data-lib 1.1 / Racket 6.12
                  interval-map-remove!
                  interval-map-expand!
                  interval-map-contract!)
         racket/async-channel
         racket/class
         racket/contract/option
         racket/match
         syntax-color/module-lexer)

(provide hash-lang%
         (struct-out token)
         generation/c
         position/c
         max-position)

;; To coordinate inter-process updates and queries we use a monotonic
;; "generation". A new object is generation 0. Thereafter the client
;; should increment the generation for every call to update!. Then,
;; when it needs to use some query operation such as classify, it
;; supplies both its latest generation and the position. The query op
;; will block until/unless we have finished updating (a) that
;; generation (b) through that position.
(define generation/c exact-nonnegative-integer?)

;; Most of our interface and implementation uses 1-based positions --
;; as do lexers and Emacs. However the color-textoid<%> methods use
;; 0-based positions, and adjust.
(define position/c exact-positive-integer?)
(define min-position 1)
(define max-position (sub1 (expt 2 63)))

;; color-textoid<%> added around Racket 8.3.0.8 / syntax-color-lib 1.3.
;; When running on older versions, this will fail, and we'll also set
;; hash-lang% to #f for hash-lang-bridge.rkt to notice and give the user
;; an error message.
(define color-textoid<%>
  (with-handlers ([exn:fail? (λ _ #f)])
    (dynamic-require 'syntax-color/color-textoid 'color-textoid<%>)))

(define (make-hash-lang%-class)
  (class* object% (color-textoid<%>)
    (super-new)
    (init-field [on-notify #f]) ;(or/c #f procedure?)
    ;; A new object has an empty string and is at generation 0. The
    ;; creator should then use update! to set a string value. That way
    ;; both `new` and `update!` return immediately; all
    ;; (re)tokenization is handled uniformly on the dedicated updater
    ;; thread.
    (define content           "")
    (define generation        0)
    (define tokens            (make-interval-map))
    (define modes             (make-interval-map))
    (define update-chan       (make-async-channel))
    (define updated-thru      0)
    ;; These members correspond to various lang-info items.
    (define lexer             default-lexer)
    (define paren-matches     default-paren-matches)
    (define quote-matches     default-quote-matches)
    (define grouping-position default-grouping-position)
    (define line-indenter     default-line-indenter)
    (define range-indenter    default-range-indenter)

    ;; This must be called from update! because the #lang in the
    ;; source could have changed and we might need new values for all
    ;; of these. Although it might be unnecessary to call for updates
    ;; beyond the #lang near the beginning, that is the safest thing
    ;; to do for now.
    (define/private (refresh-lang-info!)
      (define info
        (or (with-handlers ([values (λ _ #f)])
              (read-language (open-input-string content) (λ _ #f)))
            (λ (_key default) default)))
      (set! lexer (info 'color-lexer (waive-option module-lexer)))
      (set! paren-matches (info 'drracket:paren-matches default-paren-matches))
      (set! quote-matches (info 'drracket:quote-matches default-quote-matches))
      (set! grouping-position (info 'drracket:grouping-position default-grouping-position))
      (set! line-indenter (info 'drracket:indentation default-line-indenter))
      (set! range-indenter (info 'drracket:range-indentation default-range-indenter)))

    ;; These accessor methods really intended just for tests
    (define/public (-get-content) content)
    (define/public (-get-modes) modes)
    (define/public (-get-lexer) lexer)
    (define/public (-get-paren-matches) paren-matches)
    (define/public (-get-line-indenter) line-indenter)
    (define/public (-get-range-indenter) range-indenter)

    (define/public (delete)
      (async-channel-put update-chan 'quit))

    ;; (or/c #f position/c) -> (or/c #f (list/c position/c position/c token?))
    (define/private (token-ref pos)
      (and pos
           (let/ec k
             (call-with-values
              (λ () (interval-map-ref/bounds tokens pos (λ () (k #f))))
              list))))

    ;; The method signature here is similar to that of Emacs'
    ;; after-change functions: Something changed starting at POS. The text
    ;; there used to be OLD-LEN chars long, but is now NEW-STR.
    (define/public (update! gen pos old-len new-str)
      ;;(-> generation/c position/c exact-nonnegative-integer? string? any)
      (unless (< generation gen)
        (raise-argument-error 'update! "valid generation" 0 gen pos old-len new-str))
      (unless (<= min-position pos)
        (raise-argument-error 'update! "valid position" 1 gen pos old-len new-str))
      (unless (and (zero? old-len) (equal? new-str ""))
        (async-channel-put update-chan
                           (list 'update gen pos old-len new-str))))

    (define (consume-update-chan)
      (match (async-channel-get update-chan)
        ['quit null] ;let thread exit/die
        [(list 'update gen pos old-len new-str)
         (do-update! gen pos old-len new-str)
         (consume-update-chan)]))
    (thread consume-update-chan)

    (define/public (do-update! gen pos old-len new-str)
      (invalidate-paragraph-info)
      (set! generation gen)
      (set! updated-thru pos)
      (set! content
            (string-append (substring content 0 (sub1 pos))
                           new-str
                           (substring content (+ (sub1 pos) old-len))))
      (refresh-lang-info!) ;from new value of `str`
      (define diff (- (string-length new-str) old-len))
      ;; From where do we need to re-tokenize? This will be < the pos of
      ;; the change. Back up to the start of the previous token (plus any
      ;; `backup` amount the lexer may have supplied for that token) to
      ;; ensure re-lexing enough such that e.g. appending a character does
      ;; not create a separate token when instead it should be combined
      ;; with an existing token for preceding character(s).
      (define beg
        (match (token-ref (sub1 pos))
          [(list beg _end (token _ _ _ backup)) (- beg backup)]
          [#f pos]))
      ;; Expand/contract the tokens and modes interval-maps.
      (cond [(< 0 diff) (interval-map-expand!   tokens pos (+ pos diff))
                        (define orig-mode (interval-map-ref modes beg #f))
                        (interval-map-expand!   modes  beg (+ beg diff))
                        (interval-map-set!      modes  beg (+ beg diff) orig-mode)]
            [(< diff 0) (interval-map-contract! tokens pos (- pos diff))
                        (interval-map-contract! modes  beg (- beg diff))])
      ;; We want to detect tokens that did not change other than their
      ;; position being shifted by `diff`. When we've encountered enough
      ;; of those, we can conclude the re-lex has converged back to the
      ;; original lex and we need not continue further -- saving
      ;; potentially a huge amount of time/work.
      ;;
      ;; Because we are modifying the tokens interval-map, we can't rely
      ;; on it to obtain the "old" picture -- maybe we overwrote some of
      ;; the old. A naive idea is to copy the entire original interval-map
      ;; to an `old-tokens` map, but this can be extremely slow for large
      ;; maps.
      ;;
      ;; Instead use a "backup on write" approach. Populate `old-tokens`
      ;; as/when we modify the main map. Then to do `diff`-shift-only
      ;; compares, consult `old-tokens` first, else use the main map.
      (define old-tokens (make-interval-map))
      (define merely-shifted-count 0)
      (define merely-shifted-goal 3) ;2 b/c beg from prev token; +1 to be safe
      (define (set-interval beg end token)
        ;; If the "shadow" old-tokens interval-map has values, use those,
        ;; else use the main interval-map.
        (define-values (old-beg old-end old-token)
          (let-values ([(old-beg old-end old-tok) (interval-map-ref/bounds old-tokens beg #f)])
            (if (and old-beg old-end old-tok)
                (values old-beg old-end old-tok)
                (interval-map-ref/bounds tokens beg #f))))
        (cond [;; If there's no difference, possibly stop re-lexing.
               (and old-beg old-end old-token
                    (= old-beg beg)
                    (= old-end end)
                    (equal? old-token token))
               (set! merely-shifted-count (add1 merely-shifted-count))
               (define continue? (< merely-shifted-count merely-shifted-goal))
               continue?]
              [else
               ;; "Backup" the original interval(s) in the "shadow"
               ;; `old-tokens` map. Do so with the positions shifted by
               ;; `diff`, to simplify lookup and compares, above.
               (let loop ([n beg])
                 (define-values (old-beg old-end old-token)
                   (interval-map-ref/bounds tokens n #f))
                 (when (and old-beg old-end old-token)
                   (interval-map-set! old-tokens (+ old-beg diff) (+ old-end diff) old-token)
                   (when (< old-end end)
                     (loop old-end))))
               ;; Update the main map, notify this actual change, and
               ;; definitely continue re-lexing.
               (interval-map-set! tokens beg end token)
               (set! updated-thru end)
               (when on-notify
                 (on-notify paren-matches beg end token))
               #t])) ;continue
      (when on-notify (on-notify 'begin-update))
      (tokenize-string! beg set-interval)
      (set! updated-thru max-position)
      (when on-notify (on-notify 'end-update)))

    (define/private (tokenize-string! from set-interval)
      (define in (open-input-string (substring content (sub1 from))))
      (port-count-lines! in) ;important for Unicode e.g. λ
      (set-port-next-location! in 1 0 from) ;we don't use line/col, just pos
      (let tokenize-port! ([offset from]
                           [mode   (interval-map-ref modes from #f)])
        (define-values (lexeme type paren beg end backup new-mode)
          (lexer in offset mode))
        (unless (eof-object? lexeme)
          (interval-map-set! modes beg end mode)
          ;; Don't trust `lexeme`; instead get from the input string.
          (let ([lexeme (substring content (sub1 beg) (sub1 end))])
            (when (set-interval beg end (token lexeme type paren backup))
              (tokenize-port! end new-mode))))))

    ;; Block until the updater thread has progressed through at least a
    ;; given generation and also through a given position (although the
    ;; latter defaults to max-position meaning the entire string has been
    ;; re-tokenized).
    (define/public (block-until-updated-thru gen [pos max-position])
      (unless (and (>= generation gen)
                   (>= updated-thru pos))
        (sleep 0.1) ;meh!
        (block-until-updated-thru gen pos)))

    (define/public (classify gen pos)
      ;; (-> generation/c position/c (or/c #f (list/c position/c position/c))
      (block-until-updated-thru gen pos)
      (token-ref pos))

    (define/public (get-tokens [gen generation]
                               [from min-position]
                               [upto max-position]
                               [proc values])
      (block-until-updated-thru gen upto)
      (match (token-ref from)
        [(and v (list beg end _token))
         #:when (< beg upto)
         (cons (proc v)
               (get-tokens gen end upto proc))]
        [_ '()]))

    ;;; Paragraph/position info

    ;; do-update! calls invalidate-paragraph-info; the textoid
    ;; paragraph methods call validate-paragraph-info. In other words,
    ;; we don't attempt to efficiently update it; we throw it away and
    ;; rebuild if/as/when needed.
    (define position-paragraphs #f)
    (define paragraph-starts #f)
    (define/private (invalidate-paragraph-info)
      (set! position-paragraphs #f)
      (set! paragraph-starts #f))
    (define/public (validate-paragraph-info)
      (unless (and position-paragraphs paragraph-starts)
        (define-values (p-p p-s)
          (let loop ([pos 0] [para 0] [pos-para #hasheqv()] [para-pos #hasheqv((0 . 0))])
            (cond
              [(= pos (string-length content))
               (values (hash-set pos-para pos para) para-pos)]
              [(char=? #\newline (string-ref content pos))
               (loop (add1 pos) (add1 para)
                     (hash-set pos-para pos para)
                     (hash-set para-pos (add1 para) (add1 pos)))]
              [else
               (loop (add1 pos) para (hash-set pos-para pos para) para-pos)])))
        (set! position-paragraphs p-p)
        (set! paragraph-starts p-s)))


    ;;; Something for Emacs forward-sexp-function etc.

    (define/public (grouping gen pos dir limit count)
      (cond
        [(<= count 0) pos]
        [else
         (block-until-updated-thru gen
                                   (case dir
                                     [(up backward) min-position]
                                     [(down forward) max-position]))
         (let loop ([pos (sub1 pos)] ;1.. -> 0..
                    [count count])
           (define (failure-result) ;can't/didn't move
             (call-with-values (λ () (get-token-range pos)) list))
           (match (grouping-position this pos limit dir)
             [#f (failure-result)]
             [#t 'use-default-s-expression]
             [(? number? new-pos)
              (cond [(< 1 count) (loop new-pos (sub1 count))]
                    [(= new-pos pos) (failure-result)]
                    [else (add1 new-pos)])]))])) ;0.. -> 1..

    ;;; Indent

    (define/public (indent-line-amount gen pos)
      (block-until-updated-thru gen pos)
      (line-indenter this (sub1 pos))) ;1.. -> 0..

    (define/public (indent-region-amounts gen from upto)
      (block-until-updated-thru gen upto)
      (range-indenter this (sub1 from) (sub1 upto))) ;1.. -> 0..

    ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    ;;;
    ;;; color-textoid<%> methods.
    ;;;
    ;;; Needed by drracket:indentation, drracket:range-indentation,
    ;;; drracket:grouping-positon.
    ;;;
    ;;; 1. These use 0-based positions, not 1-based like the rest of
    ;;; our code.
    ;;;
    ;;; 2. Obviously these method signatures do not include any
    ;;; generation argument. However that should be OK because they're
    ;;; called only indirectly, via indent-line-amount or
    ;;; indent-region-amounts (which do take an expected generation
    ;;; and block if necessary), which call drracket:indentation or
    ;;; drracket:range-indentation supplying this object for these
    ;;; methods.

    (define/public (get-character pos)
      (if (< pos (string-length content))
          (string-ref content pos)
          #\nul))

    (define/public (get-text from upto)
      (substring content from upto))

    (define/private (get-token who pos)
      (let ([pos (add1 pos)])
        (match (or (token-ref pos)
                   (token-ref (sub1 pos))) ;make end position work
          [(list _ _ (? token? token)) token]
          [_ (error who "lookup failed: ~e" (sub1 pos))])))

    (define/public (classify-position* pos)
      (token-type (get-token 'classify-position* pos)))

    (define/public (classify-position pos)
      (define attribs (classify-position* pos))
      (if (symbol? attribs)
          attribs
          (hash-ref attribs 'type 'unknown)))

    (define/private (get-paren pos)
      (token-paren (get-token 'get-paren pos)))

    (define/public (get-token-range pos)
      (match (token-ref (add1 pos))
        [(list from upto _token) (values (sub1 from) (sub1 upto))]
        [_ (values #f #f)]))

    (define/public (last-position)
      (string-length content))

    (define/public (get-backward-navigation-limit pos)
      0)

    (define/public (position-paragraph pos [eol? #f])
      (validate-paragraph-info)
      (or (hash-ref position-paragraphs pos #f)
          (error 'position-paragraph "lookup failed: ~e" pos)))

    (define/public (paragraph-start-position para)
      (validate-paragraph-info)
      (or (hash-ref paragraph-starts para #f)
          (error 'paragraph-start-position "lookup failed: ~e" para)))

    (define/public (paragraph-end-position para)
      (validate-paragraph-info)
      (define n (hash-ref paragraph-starts (add1 para) #f))
      (if n
          (sub1 n)
          (last-position)))

    (define/public (backward-match pos cutoff)
      (backward-matching-search pos cutoff 'one))

    (define/public (backward-containing-sexp pos cutoff)
      (backward-matching-search pos cutoff 'all))

    (define/private (backward-matching-search init-pos cutoff mode)
      (define start-pos (if (and (eq? mode 'all)
                                 (init-pos . <= . cutoff))
                            cutoff
                            (sub1 init-pos)))
      (let loop ([pos start-pos]
                 [depth (if (eq? mode 'one) -1 0)]
                 [need-close? (eq? mode 'one)])
        (cond
          [(pos . < . cutoff) #f]
          [else
           (define-values (s e) (get-token-range pos))
           (define (atom)
             (if need-close?
                 s
                 (loop (sub1 s) depth #f)))
           (define sym (get-paren s))
           (cond
             [sym
              (let paren-loop ([parens paren-matches])
                (cond
                  [(null? parens)
                   ;; treat an unrecognized parenthesis like an atom
                   (atom)]
                  [(eq? sym (caar parens))
                   (and (not need-close?)
                        (if (= depth 0)
                            (cond
                              [(eq? mode 'all)
                               ;; color:text% method skips back over whitespace, but
                               ;; doesn't go beyond the starting position
                               (min (skip-whitespace e 'forward #f)
                                    init-pos)]
                              [else s])
                            (loop (sub1 s) (sub1 depth) #f)))]
                  [(eq? sym (cadar parens))
                   (cond
                     [(e . > . init-pos)
                      ;; started in middle of closer
                      (if (eq? mode 'one)
                          s
                          (loop (sub1 s) depth #f))]
                     [else (loop (sub1 s) (add1 depth) #f)])]
                  [else
                   (paren-loop (cdr parens))]))]
             [else
              (define category (classify-position pos))
              (case category
                [(white-space comment)
                 (loop (sub1 s) depth need-close?)]
                [else (atom)])])])))

    (define/public (forward-match pos cutoff)
      (let loop ([pos pos] [depth 0])
        (define-values (s e) (get-token-range pos))
        (cond
          [(not s) #f]
          [else
           (define sym (get-paren s))
           (define (atom)
             (if (zero? depth)
                 e ;; didn't find paren to match, so finding token end
                 (loop e depth)))
           (cond
             [sym
              (let paren-loop ([parens paren-matches])
                (cond
                  [(null? parens)
                   ;; treat an unrecognized parenthesis like an atom
                   (atom)]
                  [(eq? sym (caar parens))
                   (if (eqv? pos s) ; don't count the middle of a parenthesis token
                       (loop e (add1 depth))
                       e)]
                  [(eq? sym (cadar parens))
                   (cond
                     [(depth . <= . 0) #f]
                     [(depth . = . 1) e]
                     [else (loop e (sub1 depth))])]
                  [else
                   (paren-loop (cdr parens))]))]
             [else
              (define category (classify-position pos))
              (case category
                [(white-space comment) (loop e depth)]
                [else (atom)])])])))

    (define/public (skip-whitespace pos dir comments?)
      (define (skip? category)
        (or (eq? category 'white-space)
            (and comments? (eq? category 'comment))))
      (case dir
        [(forward)
         (let loop ([pos pos])
           (define category (classify-position pos))
           (cond
             [(skip? category)
              (define-values (s e) (get-token-range pos))
              (if e
                  (loop e)
                  pos)]
             [else pos]))]
        [(backward)
         (cond
           [(zero? pos) 0]
           [else
            (let loop ([pos (sub1 pos)] [end-pos pos])
              (define category (classify-position pos))
              (cond
                [(skip? category)
                 (define-values (s e) (get-token-range pos))
                 (loop (sub1 s) s)]
                [else end-pos]))])]
        [else
         (error 'skip-whitespace "bad direction: ~e" dir)]))))

(define hash-lang%
  (and color-textoid<%>
       (make-hash-lang%-class)))

(define default-lexer (waive-option module-lexer))
(define default-paren-matches '((\( \)) (\[ \]) (\{ \})))
(define default-quote-matches '(#\" #\|))
(define (default-grouping-position _obj _start _limit _direction) #t)
(define (default-line-indenter _text-like% _pos) #f)
(define (default-range-indenter _text-like% _from _upto) #f)

(struct token (lexeme type paren backup) #:transparent)
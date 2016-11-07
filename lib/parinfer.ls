;;
;; Parinfer 1.9.0-beta
;;
;; Copyright 2015-2016 © Shaun LeBron
;; MIT License
;;
;; Home Page: http://shaunlebron.github.io/parinfer/
;; GitHub: https://github.com/shaunlebron/parinfer
;;
;; For DOCUMENTATION on this file, please see `parinfer.js.md`
;;

;;------------------------------------------------------------------------------
;; Constants / Predicates
;;------------------------------------------------------------------------------

;; NOTE: this is a performance hack
;; The main result object uses a lot of "Integer or null" values.
;; Using a sentinel integer is faster than actual null because it cuts down on
;; type coercion overhead.
;; https://en.wikipedia.org/wiki/Sentinel_value
(var SENTINEL_NULL -999)

(var INDENT_MODE "INDENT_MODE")
(var PAREN_MODE "PAREN_MODE")

(var BACKSLASH "\\")
(var BLANK_SPACE " ")
(var DOUBLE_QUOTE "\"")
(var NEWLINE "\n")
(var SEMICOLON ";")
(var TAB "\t")

(var LINE_ENDING_REGEX (new RegExp "\r?\n"))

(var STANDALONE_PAREN_TRAIL (new RegExp "^[\s\]\)\}]*(;.*)?$"))

(var PARENS {"{": "}",
             "}": "{",
             "[": "]",
             "]": "[",
             "(": ")",
             ")": "("})

(function isBoolean (x)
  (= (typeof x) "boolean"))

(function isInteger (x)
  (&& (= (typeof x) "number")
      (isFinite x)
      (= x (Math.floor x))))

(function isOpenParen (c)
  (|| (= c "{") (= c "(") (= c "[")))

(function isCloseParen (c)
  (|| (= c "}") (= c ")") (= c "]")))

;;------------------------------------------------------------------------------
;; Result Structure
;;------------------------------------------------------------------------------

;; This represents the running result. As we scan through each character
;; of a given text, we mutate this structure to update the state of our
;; system.

(function getInitialResult (text options mode)
  (var result
    (object
      mode mode                ;; [enum] - current processing mode (INDENT_MODE or PAREN_MODE)

      origText text            ;; [string] - original text
      origCursorX SENTINEL_NULL
      origLines                ;; [string array] - original lines
      (text.split LINE_ENDING_REGEX)

      lines []                 ;; [string array] - resulting lines (with corrected parens or indentation)
      lineNo -1                ;; [integer] - line number we are processing
      ch ""                    ;; [string] - character we are processing (can be changed to indicate a replacement)
      x 0                      ;; [integer] - x position of the current character (ch)

      parenStack []            ;; We track where we are in the Lisp tree by keeping a stack (array) of open-parens.
                               ;; Stack elements are objects containing keys {ch, x, lineNo, indentDelta}
                               ;; whose values are the same as those described here in this result structure.

      tabStops []              ;; In Indent Mode, it is useful for editors to snap a line's indentation
                               ;; to certain critical points.  Thus, we have a `tabStops` array of objects containing
                               ;; keys {ch, x, lineNo}, which is just the state of the `parenStack` at the cursor line.

      parenTrail               ;; the range of parens at the end of a line}
      (object
        lineNo SENTINEL_NULL   ;; [integer] - line number of the last parsed paren trail
        startX SENTINEL_NULL   ;; [integer] - x position of first paren in this range
        endX SENTINEL_NULL     ;; [integer] - x position after the last paren in this range
        openers [])              ;; [array of stack elements] - corresponding open-paren for each close-paren in this range

      cursorX SENTINEL_NULL       ;; [integer] - x position of the cursor
      cursorLine SENTINEL_NULL    ;; [integer] - line number of the cursor
      cursorDx SENTINEL_NULL      ;; [integer] - amount that the cursor moved horizontally if something was inserted or deleted
      previewCursorScope false    ;; [boolean] - preview the cursor's scope on an empty line by inserting close-parens after it.
      canPreviewCursorScope false ;; [boolean] - determines if the cursor is in a valid position to allow previewing scope

      isInCode true            ;; [boolean] - indicates if we are currently in "code space" (not string or comment)
      isEscaping false         ;; [boolean] - indicates if the next character will be escaped (e.g. `\c`).  This may be inside string, comment, or code.
      isInStr false            ;; [boolean] - indicates if we are currently inside a string
      isInComment false        ;; [boolean] - indicates if we are currently inside a comment
      commentX SENTINEL_NULL   ;; [integer] - x position of the start of comment on current line (if any)

      firstUnmatchedCloseParenX SENTINEL_NULL ;; [integer] - x position of the first unmatched close paren of a line (if any)

      quoteDanger false        ;; [boolean] - indicates if quotes are imbalanced inside of a comment (dangerous)
      trackingIndent false     ;; [boolean] - are we looking for the indentation point of the current line?
      skipChar false           ;; [boolean] - should we skip the processing of the current character?
      success false            ;; [boolean] - was the input properly formatted enough to create a valid result?

      maxIndent SENTINEL_NULL  ;; [integer] - maximum allowed indentation of subsequent lines in Paren Mode
      indentDelta 0            ;; [integer] - how far indentation was shifted by Paren Mode
                               ;;  (preserves relative indentation of nested expressions)

      error                    ;; if 'success' is false, return this error to the user
      (object
        name SENTINEL_NULL     ;; [string] - Parinfer's unique name for this error
        message SENTINEL_NULL  ;; [string] - error message to display
        lineNo SENTINEL_NULL   ;; [integer] - line number of error
        x SENTINEL_NULL)       ;; [integer] - start x position of error}

      errorPosCache {}))       ;; [object] - maps error name to a potential error position}))

  ;; Make sure no new properties are added to the result, for type safety.
  ;; (uncomment only when debugging, since it incurs a perf penalty)
  ;; (Object.preventExtensions result)
  ;; (Object.preventExtensions result.parenTrail)

  ;; merge options if they are valid
  (when options
    (when (isInteger options.cursorX)
      (set result.cursorX options.cursorX)
      (set result.origCursorX options.cursorX))
    (when (isInteger options.cursorLine)
      (set result.cursorLine options.cursorLine))
    (when (isInteger options.cursorDx)
      (set result.cursorDx options.cursorDx))
    (when (isBoolean options.previewCursorScope)
      (set result.previewCursorScope options.previewCursorScope)))

  result)

;;------------------------------------------------------------------------------
;; Possible Errors
;;------------------------------------------------------------------------------

;; `result.error.name` is set to any of these
(var ERROR_QUOTE_DANGER "quote-danger")
(var ERROR_EOL_BACKSLASH "eol-backslash")
(var ERROR_UNCLOSED_QUOTE "unclosed-quote")
(var ERROR_UNCLOSED_PAREN "unclosed-paren")
(var ERROR_UNMATCHED_CLOSE_PAREN "unmatched-close-paren")
(var ERROR_UNHANDLED "unhandled")

(var errorMessages {})
(set errorMessages[ERROR_QUOTE_DANGER] "Quotes must balanced inside comment blocks.")
(set errorMessages[ERROR_EOL_BACKSLASH] "Line cannot end in a hanging backslash.")
(set errorMessages[ERROR_UNCLOSED_QUOTE] "String is missing a closing quote.")
(set errorMessages[ERROR_UNCLOSED_PAREN] "Unmatched open-paren.")
(set errorMessages[ERROR_UNMATCHED_CLOSE_PAREN] "Unmatched close-paren.")
(set errorMessages[ERROR_UNHANDLED] "Unhandled error.")

(function cacheErrorPos (result errorName lineNo x)
  (set result.errorPosCache[errorName]
    {lineNo: lineNo, x: x}))

(function error (result errorName lineNo x)
  (when (= lineNo SENTINEL_NULL)
    (set lineNo result.errorPosCache[errorName].lineNo))
  (when (= x SENTINEL_NULL)
    (set x result.errorPosCache[errorName].x))
  {parinferError: true,
   name: errorName,
   message: errorMessages[errorName],
   lineNo: lineNo,
   x: x})

;;------------------------------------------------------------------------------
;; String Operations
;;------------------------------------------------------------------------------

(function replaceWithinString (orig start end replace)
  (str
    (orig.substring 0 start)
    replace
    (orig.substring end)))

(function repeatString (text n)
  (loop (result i) ("" 0)
    (if (< i n)
      (recur (str result text) ++i)
      result)))

(function getLineEnding (text)
  ;; NOTE: We assume that if the CR char "\r" is used anywhere,
  ;;       then we should use CRLF line-endings after every line.
  (var i (text.search "\r"))
  (if (!= i -1) "\r\n" "\n"))

;;------------------------------------------------------------------------------
;; Line operations
;;------------------------------------------------------------------------------

(function isCursorAffected (result start end)
  (var x result.cursorX)
  (if (= x start end)
    (= x 0)
    (>= x end)))

(function shiftCursorOnEdit (result lineNo start end replace)
  (var oldLength (- end start))
  (var newLength replace.length)
  (var dx (- newLength oldLength))
  (if (&& (!= dx 0)
          (= result.cursorLine lineNo)
          (!= result.cursorX SENTINEL_NULL)
          (isCursorAffected result start end))
    result.cursorX+=dx))

(function replaceWithinLine (result lineNo start end replace)
  (var line result.lines[lineNo])
  (var newLine (replaceWithinString line start end replace))
  (set result.lines[lineNo] newLine)
  (shiftCursorOnEdit result lineNo start end replace))

(function insertWithinLine (result lineNo idx insert)
  (replaceWithinLine result lineNo idx idx insert))

(function initLine (result line)
  (set result.x 0)
  result.lineNo++

  ;; reset line-specific state
  (set result.commentX SENTINEL_NULL)
  (set result.indentDelta 0)
  (set result.firstUnmatchedCloseParenX SENTINEL_NULL))

;; if the current character has changed, commit its change to the current line
(function commitChar (result origCh)
  (var ch result.ch)
  (if (!= origCh ch)
    (replaceWithinLine result result.lineNo result.x (+ result.x origCh.length) ch))
  result.x+=ch.length)

;;------------------------------------------------------------------------------
;; Misc Utils
;;------------------------------------------------------------------------------

(function clamp (val minN maxN)
  (cond
    (!= minN SENTINEL_NULL) (Math.max minN val)
    (!= maxN SENTINEL_NULL) (Math.min maxN val)
    true val))

(function peek (array)
  (if (= array.length 0)
    SENTINEL_NULL
    array[array.length - 1]))

;;------------------------------------------------------------------------------
;; Character functions
;;------------------------------------------------------------------------------

(function isValidCloseParen (parenStack ch)
  (var lastParen (peek parenStack))
  (if (= lastParen SENTINEL_NULL)
    false
    (= lastParen.ch PARENS[ch])))

(function onOpenParen (result)
  (when result.isInCode
    (result.parenStack.push
      {lineNo: result.lineNo,
       x: result.x,
       ch: result.ch,
       indentDelta: result.indentDelta})))

(function onMatchedClosedParen (result)
  (var opener (peek result.parenStack))
  (set result.parenTrail.endX (+ result.x 1))
  (set result.maxIndent opener.x)
  (result.parenTrail.openers.push opener)
  (result.parenStack.pop))

(function onUnmatchedCloseParen (result)
  (when (= result.firstUnmatchedCloseParenX SENTINEL_NULL)
    (set result.firstUnmatchedCloseParenX result.x)
    (set result.parenTrail.endX (+ result.x 1))))

(function onTab (result)
  (when result.isInCode
    (set result.ch DOUBLE_SPACE)))

(function onSemicolon (result)
  (when result.isInCode
    (set result.isInComment true)
    (set result.commentX result.x)))

(function onNewline (result)
  (set result.isInComment false)
  (set result.ch ""))

(function onQuote (result)
  (cond
    result.isInStr
    (set result.isInStr false)

    result.isInComment
    (do
      (set result.quoteDanger !result.quoteDanger)
      (when result.quoteDanger
        (cacheErrorPos result ERROR_QUOTE_DANGER result.lineNo result.x)))

    true
    (do
      (set result.isInStr true)
      (cacheErrorPos result ERROR_UNCLOSED_QUOTE result.lineNo result.x))))

(function onBackslash (result)
  (set result.isEscaping true))

(function afterBackslash (result)
  (set result.isEscaping false)
  (when (= result.ch NEWLINE)
    (when result.isInCode
      (throw (error result ERROR_EOL_BACKSLASH result.lineNo (- result.x 1))))
    (onNewline result)))

(function onChar (result)
  (var ch result.ch)
  (cond
    result.isEscaping   (afterBackslash result)
    (isOpenParen ch)    (onOpenParen result)
    (isCloseParen ch)   (onCloseParen result)
    (= ch DOUBLE_QUOTE) (onQuote result)
    (= ch SEMICOLON)    (onSemicolon result)
    (= ch BACKSLASH)    (onBackslash result)
    (= ch TAB)          (onTab result)
    (= ch NEWLINE)      (onNewline result))
  (set result.isInCode (&& !result.isInComment !result.isInStr)))

;;------------------------------------------------------------------------------
;; Cursor functions
;;------------------------------------------------------------------------------

(function isCursorOnLeft (result)
  (&& (= result.lineNo result.cursorLine)
      (!= result.cursorX SENTINEL_NULL)
      (<= result.cursorX result.x)))

(function isCursorOnRight (result x)
  (&& (= result.lineNo result.cursorLine)
      (!= result.cursorX SENTINEL_NULL)
      (!= x SENTINEL_NULL)
      (> result.cursorX x)))

(function isCursorInComment (result)
  (isCursorOnRight result result.commentX))

(function handleCursorDelta (result)
  (var hasCursorDelta
    (&& (!= result.cursorDx SENTINEL_NULL)
        (= result.cursorLine result.lineNo)
        (= result.cursorX result.x)))
  (when hasCursorDelta
    result.indentDelta+=result.cursorDx))

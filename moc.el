;;; moc.el --- Master of Ceremonies -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Positron Solutions <contact@positron.solutions>

;; Author: Positron Solutions <contact@positron.solutions>
;; Keywords: convenience, outline
;; Version: 0.5.0
;; Package-Requires: ((emacs "29.4") (hide-mode-line "1.0.3"))
;; Homepage: http://github.com/positron-solutions/moc

;;; License:

;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sub-license, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:

;; The above copyright notice and this permission notice shall be included in
;; all copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Commentary:
;;
;; Master of ceremonies.  Tools for display, screen capture, and presentation:
;;
;; - fullscreen focus with highlight and playback with `moc-focus'
;; - set an exact frame resolution for capture with `moc-fixed-frame-set'
;; - subtle, disappearing cursor with `moc-subtle-cursor-mode'
;; - hide cursor entirely with `moc-hide-cursor-mode'
;; - supress all messages with `moc-quiet-mode'
;; - remap many faces with `moc-face-remap'
;; - set many options at once with `moc-dispatch'
;;
;; To all the MCs out there who go by MC Focus, my sincerest apologies for the
;; unfortunate naming collision.  We will attempt to bring glory to your name.

;;; Code:
(require 'frame)
(require 'face-remap)
(require 'rect)
(require 'transient)
(require 'hide-mode-line)

(eval-when-compile (require 'cl-lib))

(defgroup moc nil "Master of ceremonies."
  :prefix 'mc
  :group 'outline)

(defcustom moc-subtle-cursor-blinks 3
  "The number of blinks of the subtle cursor.
When using a transient cursor effect, the duration of cursor visibility
is the product of this and `moc-subtle-cursor-interval'.

\\[info] elisp::Cursor Parameters."
  :type 'integer)

(defcustom moc-subtle-cursor-interval 0.2
  "Length of cursor blink interval in seconds.
Values smaller than 0.013 will be treated as 0.013."
  :type 'number)

(defcustom moc-focus-max-height-factor 0.75
  "Focused text maximum height fraction.
This is never exceeded."
  :type 'float)

(defcustom moc-focus-max-width-factor 0.75
  "Focused text maximum width fraction.
This is never exceeded."
  :type 'float)

(defcustom moc-focus-max-area-factor 0.40
  "Focused text goal area.
Area conveniently expresses the dependency between height and width.
Text that is extremely long or extremely tall will be limited by
`moc-focus-height-factor-max' and `moc-focus-width-factor-max'.  Text that
is approximately screen-shaped will often be limited by this factor
first.  Screen proportions are taken into account, so width usually has
a larger effect on screen area than height."
  :type 'float)

(defcustom moc-focus-max-scale 20.0
  "Maximum scale of focused text.
When focusing extremely small regions, this value prevents the text from
being scaled comically large.  If you just want to render single symbols
or extremely short expressions, this setting can be used to control
excessively large results."
  :type 'float)

(defcustom moc-focus-default-remaps '(org-block-no-background)
  "A list of remap presets to apply to focused text.
Each symbol is a key of `moc-face-remap-presets'.  You can still manually
apply or clear remaps using `moc-face-remap' and `moc-face-remap-clear'.
The defaults will just be turned on to save time in the usual cases."
  :type '(repeat symbol))

(defcustom moc-screenshot-dir #'temporary-file-directory
  "Directory path or function that returns a directory path.
Directory path is a string."
  :type '(choice string function))

(defcustom moc-screenshot-type 'svg
  "What type of file to save.
Options are same as supported by the backend, `x-export-frames' for now,
either pdf (default), png, postscript, or svg.  Supported types are
determined by the compile-time configuration of cairo."
  :type '(choice (const :tag "PNG" png)
                 (const :tag "Scalable Vector Graphics" svg)
                 (const :tag "PDF" pdf)
                 (const :tag "Postscript" postscript)))

(defcustom moc-fixed-frame-sizes
  '((youtube-short . (1080 . 1920))
    (1080p . (1920 . 1080))
    (2k . (2560 . 1440))
    (4k . (3840 . 2160))
    (fullscreen . fullboth))
  "Frequent screen capture resolutions.
Form is one of:

- (NAME . (WIDTH . HEIGHT))

- (NAME . FULLSCREEN)

NAME is a symbol, WIDTH and HEIGHT are integers, and FULLSCREEN
is valid value for the `fullscreen' frame parameter.

\\[info] elisp::Frame Parameters"
  :type '(cons symbol
               (choice (cons number number)
                       symbol)))

(defcustom moc-face-remap-presets
  '((bold . ((default :weight bold)))
    (org-block-no-background . ((org-block :background nil :extend nil))))
   "Face remapping presets.
Value is an alist.  Each entry should be a cons of SYMBOL PRESET.
SYMBOL will be used to choose the PRESET.  PRESET is an ALIST where each
element of PRESET is a cons of FACE SPECS where SPECS is one of the
forms understood by `face-remap-add-relative'.

\\[info] elisp::Face Remapping"
  :type 'alist)

(defvar moc--quiet-old-inhibit-message nil)

;; TODO naming consistency
(defvar moc--blink-cursor-old nil)
(defvar moc--subtle-cursor-dead-windows nil
  "Store windows where the cursor was left off.")
(defvar moc--subtle-cursor-old-point-buffer nil
  "Last position of the cursor when blinking was started.")
(defvar moc-subtle-cursor-timer nil
  "Timer started from `moc-subtle-cursor-start'.
This timer calls `moc-subtle-cursor-timer-function' every
`moc-subtle-cursor-interval' seconds.")
(defvar moc-subtle-cursor-blinks-done 0
  "Number of blinks done since we started blinking on NS, X, and MS-Windows.")

(defvar-local moc--focus-overlay-specs nil
  "Serialized specifications of overlays.
Structure is a list of (BEG END . PROPS) where PROPS comes from
`overlay-properties.'")
(defvar-local moc--focus-invisibilty-spec nil
  "The invisibility spec from the source.
Same structure as valid values for `buffer-invisibility-spec'.")
(defvar-local moc--focus-overlays nil
  "Overlays applied from `moc--focus-overlay-specs'.")
(defvar-local moc--focus-scale-overlay nil
  "Overlay responsible for scaling content.")
(defvar-local moc--focus-highlight-overlays nil
  "Overlays used to highlight focused text.
Each region is a cons of BEG END.  In actuality these overlays are a
negative image of highlighted spans.  They add the shadow face to
non-highlighted text.")
(defvar-local moc--focus-highlights nil
  "List of highlighted regions.
Each region is a cons of BEG END.")
(defvar-local moc--focus-occluding-overlays nil
  "Overlays used to occlude.
Unlike the so-called highlight overlays, these overlays really do
occlude text and their implementation is a bit simpler.")
(defvar-local moc--focus-occludes nil
  "List of occluded regions.")
(defvar-local moc--focus-cleaned-text nil
  "Copy of cleaned input text for replay expressions.")
(defvar-local moc--focus-old-fringe-background nil
  "For restoring the fringe background.")
(defvar-local moc--focus-old-subtle-cursor nil
  "Whether subtle cursor was active before running MC.")
(defvar-local moc--focus-old-quiet nil
  "Whehter quiet mode was active before running MC.")
(defvar-local moc--focus-old-window-config nil)

(defvar-local moc-focus-base-buffer nil
  "Stores a reference to the buffer MC was called from.
Focus buffers can be discarded a lot.  This allows buffer locals of a
base buffer to be relied upon for implementing things.")

(defvar moc--fixed-frame-timer nil)

(defvar-local moc--face-remap-cookies nil)

;; * Mass Face Remapping

(defun moc--read-remap (&optional preset)
  "Prompt for a preset.
PRESET is passed from elisp programs to load pre-deteremined presets."
  (when-let* ((key (or preset
                      (completing-read
                       "Choose a remap preset: "
                       moc-face-remap-presets))))
    (cdr (assoc-string key moc-face-remap-presets))))

(defun moc-face-remap-clear ()
  "Unmap any previously remapped faces."
  (interactive)
  (while-let ((cookie (pop moc--face-remap-cookies)))
    (face-remap-remove-relative cookie)))

;;;###autoload
(defun moc-face-remap (remap &optional keep-existing)
  "Remap many faces at once.
REMAP can be a symbol specifying a preset or an alist of FACE REMAP
pairs.  If any faces have already been remapped, you can pass non-nil
KEEP-EXISTING"
  (interactive (list (moc--read-remap) current-prefix-arg))
  (unless keep-existing
    (moc-face-remap-clear))
  ;; TODO anonymous remapping, perhaps informed by text properties at point to
  ;; select the correct face?
  (let ((remap (if (symbolp remap)
                   (or (moc--read-remap remap)
                       (user-error "Remapping not found"))
                 remap)))
    (mapc (lambda (r)
            (let ((face (car r))
                  (specs (cdr r)))
              (push (face-remap-add-relative face specs)
                    moc--face-remap-cookies)))
          remap)))

;; * Hide Cursor Mode

(defvar moc-subtle-cursor-mode)          ; compiler appeasement

(define-minor-mode moc-hide-cursor-mode
  "Make cursor completely hidden."
  :group 'master-of-ceremonies
  (cond
   (moc-hide-cursor-mode
    (if (minibufferp)
        (moc-hide-cursor-mode -1)
      (when moc-subtle-cursor-mode
        (moc-subtle-cursor-mode -1))
      (setq-local cursor-type nil)))
   (t
    (setq-local cursor-type (default-value 'cursor-type)))))

;; * Subtle Cursor Mode

(defun moc-subtle-cursor-start ()
  "Start the `moc-subtle-cursor-timer'.
This starts the timer `moc-subtle-cursor-timer', which makes the cursor
blink if appropriate."
  (cond
   ;; stale hook fired
   ((null moc-subtle-cursor-mode) (moc-subtle-cursor-mode -1))
   (t
    ;; TODO detect when buffer contents were changed but cursor stayed in the
    ;; same place.
    (setq moc--subtle-cursor-old-point-buffer
          (cons (point) (current-buffer)))
    (when moc-subtle-cursor-timer
      (cancel-timer moc-subtle-cursor-timer))
    ;; TODO figure out the termination for 1 blink
    (setq moc-subtle-cursor-blinks-done 1)
    (setq moc-subtle-cursor-timer
          (run-with-timer (max 0.013 moc-subtle-cursor-interval)
                          (max 0.013 moc-subtle-cursor-interval)
                          #'moc-subtle-cursor-timer-function))
    ;; Use the `cursor-type' ON-STATE
    (internal-show-cursor nil t))))

(defun moc-subtle-cursor-timer-function ()
  "Timer function of timer `moc-subtle-cursor-timer'."
  (when moc-subtle-cursor-mode
    (internal-show-cursor nil (not (internal-show-cursor-p))))
  ;; Suspend counting blinks when the w32 menu-bar menu is displayed,
  ;; since otherwise menu tooltips will behave erratically.
  (or (and (fboundp 'w32--menu-bar-in-use)
           (w32--menu-bar-in-use))
      ;; XXX guarding this expression upsets the blink count and I don't know
      ;; how it's supposed to work.
      (setq moc-subtle-cursor-blinks-done (1+ moc-subtle-cursor-blinks-done)))
  ;; Each blink is two calls to this function.
  (when (and (> moc-subtle-cursor-blinks 0)
             (>= moc-subtle-cursor-blinks-done (* 2 moc-subtle-cursor-blinks)))
    (when moc-subtle-cursor-timer (cancel-timer moc-subtle-cursor-timer)
          (setq moc-subtle-cursor-timer nil))
    (push (selected-window) moc--subtle-cursor-dead-windows)
    (when (internal-show-cursor-p)
      (message "Subtle cursor cancelled timer in ON-STATE"))))

(defun moc-subtle-cursor--should-blink ()
  "Determine whether we should be blinking.
Returns whether we have any focused non-TTY frame."
  (and moc-subtle-cursor-mode
       (not (and (eq (point) (car moc--subtle-cursor-old-point-buffer))
                 (eq (current-buffer)
                     (cdr moc--subtle-cursor-old-point-buffer))))
       (let ((frame-list (frame-list))
             (any-graphical-focused nil))
         (while frame-list
           (let ((frame (pop frame-list)))
             (when (and (display-graphic-p frame) (frame-focus-state frame))
               (setf any-graphical-focused t)
               (setf frame-list nil))))
         any-graphical-focused)))

(defun moc-subtle-cursor-check ()
  "Check if cursor blinking shall be restarted.."
  (when (moc-subtle-cursor--should-blink)
    (moc-subtle-cursor-start)))

;;;###autoload
(define-minor-mode moc-subtle-cursor-mode
  "Like `blink-cursor-mode' but leaves cursor off.
This is a modification of `blink-cursor-mode' that immediately
transitions to the ON-STATE when commands are entered and finishes
blinking in the OFF-STATE, enabling customization of `cursor-type' and
`blink-cursor-alist' to achieve a transient cursor or a very subtle
cursor when the user is not moving the point.

\\[info] elisp::Cursor Parameters.

When you do anything to move the cursor, it will remain visible for the
product of `moc-subtle-cursor-blinks' and `moc-subtle-cursor-duration'.

Because this mode conflicts with `blink-cursor-mode', it is turned off when
found active.

🚧 The mode is experimental."
  :global t
  (cond
   (moc-subtle-cursor-mode
    (setq moc--blink-cursor-old blink-cursor-mode)
    (when blink-cursor-mode
      (blink-cursor-mode -1))
    (when moc-hide-cursor-mode
      (moc-hide-cursor-mode -1))
    (add-function :after after-focus-change-function
                  #'moc-subtle-cursor-check)
    (add-hook 'after-delete-frame-functions #'moc-subtle-cursor-check)
    (add-hook 'post-command-hook #'moc-subtle-cursor-check)
    (moc-subtle-cursor-check))
   (t
    (remove-hook 'post-command-hook #'moc-subtle-cursor-check)
    (remove-hook 'after-delete-frame-functions #'moc-subtle-cursor-check)
    (remove-function after-focus-change-function
                     #'moc-subtle-cursor-check)
    (when moc-subtle-cursor-timer
      (cancel-timer moc-subtle-cursor-timer))
    ;; Make sure to leave the cursor in the ON-STATE in all windows when
    ;; quitting.
    ;; TODO seems like this never actually happens.  Cursor has an alternate
    ;; state when left around in another window, regardless of whether it was
    ;; blink on or off when the window changed.
    (while-let ((win (pop moc--subtle-cursor-dead-windows)))
      (internal-show-cursor win t))
    ;; Selected window likely not in above dead window cleanup and could be in
    ;; blink off state.
    (internal-show-cursor nil t)
    (setq moc--subtle-cursor-old-point-buffer nil)
    (when moc--blink-cursor-old
      (blink-cursor-mode 1)
      (setq moc--blink-cursor-old nil)))))

;; * Quiet mode

;;;###autoload
(define-minor-mode moc-quiet-mode
  "Inhibit messages in the echo area.
⚠️ Inhibiting messages is a bit dangerous.  If anything fails, because messages
are disabled, there may be no obvious user feedback ☠️"
  :group 'master-of-ceremonies
  :global t
  (cond
   (moc-quiet-mode
    ;; Naturally the manual sets not to set this, but the point is that the user
    ;; doesn't want to have messages for a while.  If it is never to be turned
    ;; off, how else can messages be avoided except case by case with
    ;; let-binding?
    (unless inhibit-message
      (setq moc--quiet-old-inhibit-message inhibit-message
            inhibit-message t)))
   (t
    (setq inhibit-message moc--quiet-old-inhibit-message))))

;; * Fixed Frame Size

(defun moc--fixed-frame-check-cleanup ()
  "Clean up hook if not guarding any more frames."
  (let ((frames (frame-list))
        guarded)
    (while (and frames (not guarded))
      (when (frame-parameter (pop frames) 'moc--fixed-frame-notify)
        (setq guarded t)))
    (unless guarded
      (remove-hook 'window-size-change-functions #'moc--fixed-frame-notify))))

(defun moc--fixed-frame-release (frame)
  "Release FRAME from size management.
Allow state cleanup if no more frames are under management."
  (set-frame-parameter frame 'moc--fixed-frame-goal nil)
  (moc--fixed-frame-check-cleanup))

(defun moc--fixed-frame-notify (frame)
  "Check if FRAME has the right size."
  (if (frame-parameter frame 'fullscreen)
      ;; Only frames with a non-fullscreen size are guarded, so we bail if they
      ;; have acquired a fullscreen parameter.
      (progn (message "Frame: %s has become fullscreen.  Releasing." frame)
             (moc--fixed-frame-release frame))
    (when-let* ((size (frame-parameter frame 'moc--fixed-frame-goal)))
      (moc--fixed-frame-verify frame size))))

(defun moc--fixed-frame-verify (frame size)
  "Verify FRAME is SIZE or schedule correction."
  (let ((width-correction (- (car size) (frame-pixel-width frame)))
        (height-correction (- (cdr size) (frame-pixel-height frame))))
    (unless (and (= width-correction 0)
                 (= height-correction 0)
                 (null moc--fixed-frame-timer))
      (setq moc--fixed-frame-timer
            (run-with-timer 0.0 nil #'moc--fixed-frame-correct-all)))))

;;;###autoload
(defun moc-fixed-frame-release-all ()
  "Release all guarded frames."
  (interactive)
  (let ((frames (frame-list)))
    (while-let ((frame (pop frames)))
      (set-frame-parameter frame 'moc--fixed-frame-goal nil))
    (moc--fixed-frame-check-cleanup)))

(defun moc--fixed-frame-correct (frame size &optional no-set)
  "Check and correct that FRAME is SIZE.
When optional NO-SET is non-nil, only check and set once.  Otherwise
set, check and set."
  ;; Its necessary to set once to find the correction needed to get the exact
  ;; frame size we want.  This same function can set up for itself and will not
  ;; do unnecssary work if no correction is needed.
  (unless no-set (moc--fixed-frame-set frame size))
  (let ((width-correction (- (car size) (frame-pixel-width frame)))
        (height-correction (- (cdr size) (frame-pixel-height frame))))
    (unless (and (= width-correction 0)
                 (= height-correction 0))
      (let ((frame-resize-pixelwise t))
        (message "making corrections: %sw %sh"
                 width-correction height-correction)
        (set-frame-size frame
                        (+ (car size) width-correction)
                        (+ (cdr size) height-correction)
                        t))
      (message "corrected size: %sw %sh"
               (frame-pixel-width frame)
               (frame-pixel-height frame)))))

(defun moc--fixed-frame-correct-all ()
  "Used as a single-call post-command hook to avoid thrashing."
  ;; Updating the frame size during the `window-size-change-functions' is not a
  ;; good idea.  Temporarily removing the hook was an ineffective strategy in
  ;; this case.  Instead, this function runs in the post command hook and, if
  ;; added, corrects all frames and removes itself.
  (setq moc--fixed-frame-timer nil)
  (dolist (frame (frame-list))
    (if (frame-parameter frame 'fullscreen)
        ;; Only frames with a non-fullscreen size are guarded, so we bail if they
        ;; have acquired a fullscreen parameter.
        (progn (message "Frame: %s has become fullscreen.  Releasing." frame)
               (moc--fixed-frame-release frame))
      (when-let* ((size (frame-parameter frame 'moc--fixed-frame-goal)))
        (moc--fixed-frame-correct frame size)))))

(defun moc--fixed-frame-set (frame size)
  "Set SIZE on FRAME.
SIZE is either a (H . W) cons or a symbol that can be used as a frame
parameter for `fullscreen'."
  (if (consp size)
      (unless (and (= (car size) (frame-pixel-width frame))
                   (= (cdr size) (frame-pixel-height frame)))
        (let ((frame-resize-pixelwise t))
          (set-frame-parameter nil 'fullscreen nil)
          (set-frame-size nil (car size) (cdr size) t)
          (message "set size: %sw %sh"
                   (frame-pixel-width frame)
                   (frame-pixel-height frame))
          (moc--fixed-frame-correct frame size t)))
    (set-frame-parameter nil 'fullscreen size)
    (message "fullscreen: %s" size)))

;;;###autoload
(defun moc-fixed-frame-set (frame-size)
  "Set and maintain a fixed FRAME-SIZE.
FRAME-SIZE is either a key for `moc-fixed-frame-sizes' or a valid value
of it.

Will correct the frame size if any window manager silliness attempts to
make your frame another size.  Adds a hook to preserve the desired frame
size.

🚧 This feature is experimental and has some behaviors that may be
confusing.  A fixed frame will be released if it is converted to full
screen.  Only fixed frames have their size maintained.  When resizing
with a mouse, the resize will appear successful, but then the size will
revert after the first command.  With the right comination of hooks,
these behaviors may become more consistent."
  (interactive (list (completing-read
                      "Select size: "
                      (if (frame-parameter (selected-frame)
                                           'moc--fixed-frame-revert)
                          (cons 'revert moc-fixed-frame-sizes)
                        moc-fixed-frame-sizes))))
  (let* ((frame (selected-frame))
         (revert (string= frame-size "revert"))
         (new (cond
               (revert
                (frame-parameter (selected-frame) 'moc--fixed-frame-revert))
               ((stringp frame-size)
                (cdr (assoc-string frame-size moc-fixed-frame-sizes)))
               ((symbolp frame-size)
                (cdr (assq frame-size moc-fixed-frame-sizes)))
               ((consp frame-size) frame-size)
               (t (error "Unrecognized size: %s" frame-size))))
         (current (if-let* ((fullscreen (frame-parameter nil 'fullscreen)))
                      fullscreen
                    (cons (frame-pixel-width)
                          (frame-pixel-height)))))
    (set-frame-parameter nil 'moc--fixed-frame-revert (if revert nil current))
    (moc--fixed-frame-set frame new)
    (when (consp new)
      (if revert
          (set-frame-parameter frame 'moc--fixed-frame-goal nil)
        (set-frame-parameter frame 'moc--fixed-frame-goal new)
        (add-hook 'window-size-change-functions #'moc--fixed-frame-notify)))))

;; * Master of Ceremonies Dispatch
;; Let us tie everything together into.  A transient.

;; There isn't a ton of consistency in how these are used.  Still in the
;; trial-and-error phase of building up an in-transient UI

(defun moc--dispatch-frame-size ()
  "Return frame size for use in info class."
  (format
   "current: %s"
   (propertize
    (if-let* ((full (frame-parameter nil 'fullscreen)))
        (symbol-name full)
      (format "%s %s" (frame-pixel-width) (frame-pixel-height)))
    'face 'transient-value)))

(defun moc--dispatch-fixed-frames ()
  "Return description for clearing fixed frames.
Used in suffix command."
  (let ((frames (frame-list))
        (fixed 0))
    (while-let ((frame (pop frames)))
      (when (frame-parameter frame 'moc--fixed-frame-goal)
        (setq fixed (1+ fixed))))
    (format
     "release %-3s"
     (if (> fixed 0)
         (propertize (format "%3s frames" fixed) 'face 'success)
       ""))))

(defun moc--dispatch-cursor-mode ()
  "Return cursor state for use in info class."
  (if-let* ((cursor (if (consp cursor-type)
                       (car cursor-type)
                     (if (eq cursor-type t)
                         (frame-parameter nil 'cursor-type)
                       cursor-type))))
      (if moc-subtle-cursor-mode
          (propertize (format "subtle %-4s" cursor)
                      'face 'transient-value)
        (propertize (format "%-11s" (symbol-name cursor))
                    'face 'transient-value))
    (propertize "hidden     " 'face 'shadow)))

(defun moc--dispatch-faces-remapped ()
  "Return remap clear description including current remap state.
Use in suffix command."
  (let ((remaps (length moc--face-remap-cookies)))
    (format
     "clear %s"
     (if (> remaps 0)
         (propertize (format "remaps %-4d" remaps) 'face 'success)
       ""))))

(defun moc--dispatch-text-scale ()
  "Return current text scale for info class."
  (if text-scale-mode
      (propertize (format "scale: %s" text-scale-mode-amount)
                  'face 'transient-value)
    (propertize "off" 'face 'shadow)))

(defun moc--dispatch-quiet-mode ()
  "Return description and quiet mode state for suffix."
  (format
   "quiet %s"
   (if moc-quiet-mode
       (propertize "on " 'face 'success)
     (propertize "off" 'face 'shadow))))

;;;###autoload (autoload 'moc-dispatch "moc" nil t)
(transient-define-prefix moc-dispatch ()
  "You are the MC.
This is likely the command you want to bind globally to become familiar
with MC commands and to make many adjustments at once."
  :refresh-suffixes t
  [["Buffer Text Scale"
    (:info #'moc--dispatch-text-scale)
    ("t+" "increase" text-scale-increase :transient t)
    ("t-" "decrease" text-scale-decrease :transient t)
    ("t=" "reset" text-scale-mode :transient transient--do-call
     :inapt-if-non-nil text-scale-mode)]]
  ["Fixed Frame"
   (:info #'moc--dispatch-frame-size)
   ("s" "set" moc-fixed-frame-set :transient t)
   ("R" moc-fixed-frame-release-all :transient t
    :description moc--dispatch-fixed-frames)]
  ["Face Remapping"
   ("r" "remap" moc-face-remap :transient t)
   ("c" moc-face-remap-clear :transient t
    :description moc--dispatch-faces-remapped)]
  [["Cursor"
    (:info #'moc--dispatch-cursor-mode)
    ("?" "hide" moc-hide-cursor-mode :transient t)
    ("." "subtle" moc-subtle-cursor-mode :transient t)]
   ["Mode Line"
    ("m" "hide" hide-mode-line-mode :transient t)]
   ["Echo area"
    ("e" moc-quiet-mode :transient t
     :description moc--dispatch-quiet-mode)]])

;; * Screenshot

;; 🚧 If you consider working on this feature, support for other file type
;; support and naming support for workflows like animation are good to add along
;; the way.  There are other packages for building gifs etc that would be
;; welcome in MC as optional dependencies.

(defun moc--screenshot-save-dir ()
  "Return the users screenshot save path, which may be computed."
  (if (stringp moc-screenshot-dir)
      moc-screenshot-dir
    (if (functionp moc-screenshot-dir)
        (or (funcall moc-screenshot-dir)
            default-directory)
      default-directory)))

;;;###autoload
(defun moc-screenshot ()
  "Save a screenshot of the current frame as an SVG image.
This just provides minor conveniences like pre-configured save path with
`moc-screenshot-dir'."
  (interactive)
  (let* ((timestamp (format-time-string "%F-%H:%M:%S" (current-time)))
         (filename (format "screenshot-%s.svg" timestamp))
         (dir (moc--screenshot-save-dir))
         (path (concat dir filename))
         (data (x-export-frames nil moc-screenshot-type)))
    (unless (file-exists-p dir)
      (make-directory dir t))
    (with-temp-file path
      (insert data))
    (message "Saved to: %s" filename)))

;; * Focus Fullscreen Text

;; Only add to the `buffer-list-update-hook' locally so we don't need to unhook
(defun moc--focus-refresh (window)
  "Refresh buffer in WINDOW if buffer is visible again."
  (when (eq (window-buffer window) (get-buffer "*MC Focus*"))
    (set-window-fringes window 0 0)
    (set-face-attribute 'fringe (window-frame window)
                        :background 'unspecified)
    (set-window-margins window nil)))

(defun moc--focus-apply-overlays (overlay-specs &optional offset)
  "Apply OVERLAY-SPECS to the buffer.
OVERLAY-SPECS is a list of (BEG END . PROPS) where PROPS is obtained
from `overlay-properties'."
  (while-let ((o (pop overlay-specs)))
    (let* ((offset (or offset 0))
           (beg (+ (pop o) offset))
           (end (+ (pop o) offset))
           (ov (make-overlay beg end nil t nil)))
      (while-let ((prop (pop o)))
        (overlay-put ov prop (pop o)))
      (push ov moc--focus-overlays))))

(defun moc--focus-cleanup ()
  "Clean up state for focus buffer upon kill."
  (remove-hook 'window-state-change-functions #'moc--focus-refresh)
  ;; hidden cursor is buffer local and naturally goes away, but subtle cursor is
  ;; global and needs to be turned off if it wasn't on when focusing began.
  ;; XXX two MC buffers could restore a modified value
  (when moc--focus-old-fringe-background
    (set-face-attribute 'fringe (selected-frame) :background
                        moc--focus-old-fringe-background))
  (if (not moc--focus-old-quiet)
      (when moc-quiet-mode
        (moc-quiet-mode -1))
    (setq moc--focus-old-quiet nil)
    (unless moc-quiet-mode
      (moc-quiet-mode 1)))
  (if (not moc--focus-old-subtle-cursor)
      (when moc-subtle-cursor-mode
        (moc-subtle-cursor-mode -1))
    (setq moc--focus-old-subtle-cursor nil)
    (unless moc-subtle-cursor-mode
      (moc-subtle-cursor-mode 1)))

  (when moc--focus-old-window-config
    (set-window-configuration moc--focus-old-window-config))
  (setq moc--focus-old-window-config nil
        moc--focus-cleaned-text nil))

;; 🚧 Presently this code does a good job on the first pass and replay.
;; However, displaying in other buffers or re-displaying the buffer in another
;; window will likely leave something to be desired.
(defun moc--display-fullscreen (&rest args)
  "Show TEXT with properties in a fullscreen window.
See `mc-focus' for meaning of keys in ARGS."
  (when-let* ((old (get-buffer "*MC Focus*")))
    (kill-buffer old))
  (setq moc--focus-old-window-config (current-window-configuration))
  (let* ((base (current-buffer))
         (buffer (get-buffer-create "*MC Focus*"))
         (text (moc--focus-clean-properties (plist-get args :string)))
         (overlay-specs (plist-get args :overlays))
         (invisibility-spec (plist-get args :invisibility-spec))
         (highlights (plist-get args :highlights))
         (occludes (plist-get args :occludes)))
    (delete-other-windows)
    (let ((inhibit-message t))
      (switch-to-buffer buffer))
    (setq-local moc-focus-base-buffer base)
    (add-hook 'kill-buffer-hook #'moc--focus-cleanup nil t)
    (moc-focus-mode)
    (setq-local mode-line-format nil)
    (setq moc--focus-old-fringe-background (face-attribute 'fringe :background))
    (set-face-attribute 'fringe (selected-frame) :background 'unspecified)
    (setq buffer-invisibility-spec invisibility-spec)
    (setq moc--focus-invisibilty-spec invisibility-spec)
    (setq moc--focus-old-quiet
          moc-quiet-mode)
    (setq moc--focus-old-subtle-cursor
          moc-subtle-cursor-mode)
    (moc-hide-cursor-mode 1)
    (moc-quiet-mode 1)
    ;; TODO minibuffer messages are not cleared immediately when replaying with
    ;; interactive evaluation.  The result of this function is displayed.  Yuck.
    (read-only-mode -1)

    ;; Before we start adding properties, save the input text without additional
    ;; properties.
    (setq-local moc--focus-cleaned-text text)
    (insert (propertize text 'line-prefix nil 'wrap-prefix nil))
    (setq-local moc--focus-overlay-specs overlay-specs)
    (when overlay-specs
      (moc--focus-apply-overlays overlay-specs))

    (mapc (lambda (remap) (moc-face-remap remap t))
          moc-focus-default-remaps)

    (setq moc--focus-highlights highlights)
    ;; TODO distinguish fully shadowed versus no highlights
    (when highlights
      (moc--focus-apply-highlights highlights))

    (setq moc--focus-occludes occludes)
    (when occludes
      (moc--focus-apply-occludes occludes))

    (let* ((w (window-pixel-width))
           (h (window-pixel-height))
           (window-pixel-area (* h w))
           (text-pixel-size (window-text-pixel-size))
           (text-pixel-w (float (car text-pixel-size)))
           (text-pixel-h (float (cdr text-pixel-size)))
           (text-pixel-area (* text-pixel-w text-pixel-h))
           (max-scale-horizontal (/ (* w moc-focus-max-width-factor)
                                    text-pixel-w))
           (max-scale-vertical (/ (* h moc-focus-max-height-factor)
                                  text-pixel-h))
           (max-scale-by-area (/ (* window-pixel-area
                                    moc-focus-max-area-factor)
                                 text-pixel-area))
           (scale (min max-scale-horizontal
                       max-scale-vertical
                       max-scale-by-area
                       moc-focus-max-scale))
           (scale-overlay (make-overlay 1 (point-max))))
      (overlay-put scale-overlay 'face `(:height ,scale))
      (overlay-put scale-overlay 'priority 9999)
      (setq moc--focus-scale-overlay scale-overlay)

      ;; Now that the text is its final size, adjust the vertical and horizontal
      ;; alignment.
      (let* ((text-size (window-text-pixel-size))
             (margin-left (floor (/ (- w (car text-size)) 2.0)))
             (margin-top (/ (- h (cdr text-size)) 2.0))
             (margin-lines (/ margin-top (frame-char-height))))

        (set-window-fringes (selected-window) 0 0)
        (set-window-margins (selected-window) nil nil)
        (add-hook 'window-state-change-functions #'moc--focus-refresh nil t)

        ;; TODO dynamically maintain specified space
        (let ((o (make-overlay (point-min) (point-max))))
          (overlay-put o 'line-prefix
                       (propertize " " 'display
                                   `(space :align-to (,margin-left))))
          (overlay-put o 'priority 9999))
        (goto-char 0)
        (insert (propertize "\n" 'face `(:height ,margin-lines)))
        (setf (overlay-start scale-overlay) 2)
        (setf (overlay-end scale-overlay) (point-max))))
    (read-only-mode 1)))

(defun moc--focus-apply-highlights (highlights)
  "Replay HIGHLIGHTS from Elisp programs.
HIGHLIGHTS is a list of conses of BEG END to be highlighted.  Regions
not contained by some BEG END will have the shadow face applied.
HIGHLIGHTS must be partially ordered and with no overlaps or else
behavior is not guaranteed."
  (let (un-highlights left right)
    (mapc #'delete-overlay moc--focus-highlight-overlays) ; 🤡 almost forgot
    ;; no highlights means shadow everything
    (unless highlights
      (push (cons (point-min) (point-max))
            un-highlights))
    ;; before the first highlight
    (unless (or (null highlights)
                (and highlights
                     (= (caar highlights) (point-min))))
      (push (cons (point-min) (caar highlights))
            un-highlights))
    ;; un-highlight in between every two highlights
    (setq left (pop highlights))
    (setq right (pop highlights))
    (while right
      (push (cons (cdr left) (car right))
            un-highlights)
      (setq left right)
      (setq right (pop highlights)))
    ;; after the last highlight
    (unless (or (null left)
                (and left (= (cdr left) (point-max))))
      (push (cons (cdr left) (point-max))
            un-highlights))
    ;; apply all unhighlights
    (dolist (h un-highlights)
      (let ((o (make-overlay (car h) (cdr h))))
        ;; TODO customize un-highlight face
        (overlay-put o 'face 'shadow)
        (push o moc--focus-highlight-overlays)))))

(defun moc--focus-un-highlight (beg end)
  "Remove region between BEG and END from highlights.
Preserves total ordering of highlighted spans."
  (let ((highlights moc--focus-highlights)
        keep)
    (while-let ((h (pop highlights)))
      ;; If BEG and END include either or both ends of a highlight, we have to
      ;; modify spans.
      (let ((h-beg-interior (and (>= (car h) beg)
                                 (<= (car h) end)))
            (h-end-interior (and (>= (cdr h) beg)
                                 (<= (cdr h) end)))
            (h-beg-before (< (car h) beg))
            (h-end-after (> (cdr h) end)))
        (cond
         ;; fully contained highlights are omitted
         ((and h-beg-interior h-end-interior) nil)
         ;; intersected highlights are trimmed
         (h-beg-interior (push (cons end (cdr h)) keep))
         (h-end-interior (push (cons (car h) beg) keep))
         ;; split highlights that contain un-highlight
         ((and h-beg-before h-end-after)
          (push (cons (car h) beg) keep)
          (push (cons end (cdr h)) keep))
         (t (push h keep)))))
    (setq moc--focus-highlights (nreverse keep))))

(defun moc--focus-un-occlude (beg end)
  "Remove region between BEG and END from occludes.
Preserves total ordering of occluded spans."
  (let ((occludes moc--focus-occludes)
        keep)
    (while-let ((o (pop occludes)))
      ;; If BEG and END include either or both ends of a occlude, we have to
      ;; modify spans.
      (let ((o-beg-interior (and (>= (car o) beg)
                                 (<= (car o) end)))
            (o-end-interior (and (>= (cdr o) beg)
                                 (<= (cdr o) end)))
            (o-beg-before (< (car o) beg))
            (o-end-after (> (cdr o) end)))
        (cond
         ;; fully contained occludes are omitted
         ((and o-beg-interior o-end-interior) nil)
         ;; intersected occludes are trimmed
         (o-beg-interior (push (cons end (cdr o)) keep))
         (o-end-interior (push (cons (car o) beg) keep))
         ;; split occludes that contain un-occlude
         ((and o-beg-before o-end-after)
          (push (cons (car o) beg) keep)
          (push (cons end (cdr o)) keep))
         (t (push o keep)))))
    (setq moc--focus-occludes (nreverse keep))))

(defun moc--focus-highlight (beg end)
  "Add region between BEG and END to highlights.
Preserves total ordering of highlighted spans."
  (let ((highlights moc--focus-highlights)
        keep merge)
    ;; push all regions ending before beg
    (while (and (car highlights)
                (< (cdar highlights) beg))
      (push (pop highlights) keep))
    ;; merge all regions that overlap or are adjacent
    (setq merge (cons beg end))
    (while (and highlights
                (or (and (>= (caar highlights) beg)
                         (<= (caar highlights) end))
                    (and (>= (cdar highlights) beg)
                         (<= (cdar highlights) end))))
      (setq merge (cons (min (caar highlights) beg)
                        (max (cdar highlights) end)))
      (pop highlights))
    (push merge keep)
    ;; push remaining regions
    (while highlights
      (push (pop highlights) keep))
    (setq moc--focus-highlights (nreverse keep))))

(defun moc--focus-occlude (beg end)
  "Add region between BEG and END to occludes.
Preserves total ordering of occluded spans."
  (let ((occludes moc--focus-occludes)
        keep merge)
    ;; push all regions ending before beg
    (while (and (car occludes)
                (< (cdar occludes) beg))
      (push (pop occludes) keep))
    ;; merge all regions that overlap or are adjacent
    (setq merge (cons beg end))
    (while (and occludes
                (or (and (>= (caar occludes) beg)
                         (<= (caar occludes) end))
                    (and (>= (cdar occludes) beg)
                         (<= (cdar occludes) end))))
      (setq merge (cons (min (caar occludes) beg)
                        (max (cdar occludes) end)))
      (pop occludes))
    (push merge keep)
    ;; push remaining regions
    (while occludes
      (push (pop occludes) keep))
    (setq moc--focus-occludes (nreverse keep))))

(defun moc--focus-apply-occludes (occludes)
  "Replay OCCLUDES from Elisp programs.
OCCLUDES is a list of conses of BEG END to be occluded."
  (let ((background (face-attribute 'default :background)))
    (mapc #'delete-overlay moc--focus-occluding-overlays)
    (while-let ((ob (pop occludes)))
      ;; Yep.  This is it.  This is all that is needed to occlude the occluded
      ;; stuff.  Making this comment longer while reflecting on how it is easier
      ;; to occlude than to "highlight".
      (let ((ov (make-overlay (car ob) (cdr ob))))
        ;; TODO does not occlude emoji glphs, which also have non-fixed sizes
        ;; TODO fringes
        (overlay-put ov 'face
                     (list :foreground background
                           :background background
                           :extend t))
        (overlay-put ov 'priority 1000) ; arbitrary
        (push ov moc--focus-occluding-overlays)))))

;; ** Focus UI Commands

(defsubst moc--focus-assert-mode ()
  "Raise user error if commands are called in wrong mode."
  (if-let* ((buffer (get-buffer "*MC Focus*")))
      (set-buffer buffer)
    (user-error "No MC buffer found")))

(defun moc-focus-highlight-clear ()
  "Delete all highlights and occludes."
  (interactive)
  (moc--focus-assert-mode)
  (unless (or moc--focus-highlights
              moc--focus-occludes)
    (user-error "No highlights or occludes to remove"))
  (setq moc--focus-highlights nil)
  (mapc #'delete-overlay moc--focus-highlight-overlays)
  (setq moc--focus-highlight-overlays nil)
  (setq moc--focus-occludes nil)
  (mapc #'delete-overlay moc--focus-occluding-overlays)
  (setq moc--focus-occluding-overlays nil))

(put 'moc-focus-highlight-clear 'mode 'moc-focus-mode)

(defun moc-focus-quit ()
  "Fullscreen quit command."
  (interactive)
  (if-let* ((buffer (get-buffer "*MC Focus*")))
      (kill-buffer buffer)
    (user-error "No MC buffer found")))

(put 'moc-focus-quit 'mode 'moc-focus-mode)

(defun moc-focus-highlight (beg end)
  "Highlight region between BEG and END.
The shadow face will be applied to remaining unhighlighted regions."
  (interactive "r")
  (moc--focus-assert-mode)
  (moc--focus-highlight beg end)
  (moc--focus-un-occlude beg end)
  ;; unnecessary to deactivate the mark when called any other way
  (when (called-interactively-p 't)
    (deactivate-mark))
  (moc--focus-apply-highlights moc--focus-highlights)
  (moc--focus-apply-occludes moc--focus-occludes))

(put 'moc-focus-highlight 'mode 'moc-focus-mode)

(defun moc-focus-occlude (beg end)
  "Occlude region between BEG and END.
This overrides any highlights or shadows.  Use un-highlight or highlight
to make occluded regions visible again."
  (interactive "r")
  (moc--focus-assert-mode)
  (moc--focus-occlude beg end)
  ;; unnecessary to deactivate the mark when called any other way
  (when (called-interactively-p 't)
    (deactivate-mark))
  (moc--focus-apply-occludes moc--focus-occludes))

(put 'moc-focus-occlude 'mode 'moc-focus-mode)

(defun moc-focus-un-highlight (beg end)
  "Remove highlight in region between BEG and END.
The shadow face will be added to the region between BEG and END."
  (interactive "r")
  (moc--focus-assert-mode)
  (unless moc--focus-highlights
    (user-error "No highlights to un-highlight"))
  (moc--focus-un-highlight beg end)
  (moc--focus-un-occlude beg end)
  ;; unnecessary to deactivate the mark when called any other way
  (when (called-interactively-p 't)
    (deactivate-mark))
  (moc--focus-apply-highlights moc--focus-highlights)
  (moc--focus-apply-occludes moc--focus-occludes))

(put 'moc-focus-un-highlight 'mode 'moc-focus-mode)


(defun moc-focus-toggle-overlays ()
  (interactive)
  (moc--focus-assert-mode)
  (if moc--focus-overlays
      (progn (mapc #'delete-overlay
                   moc--focus-overlays)
             (setq moc--focus-overlays nil))
    (moc--focus-apply-overlays
     ;; whenever toggling overlays, a space exists at the 1 position, so we need
     ;; to offset all overlays.  When there becomes a way to add space above a
     ;; line without stretching the background for that line, let me know 😉!
     moc--focus-overlay-specs 1)))

(put 'moc-focus-toggle-overlays 'mode 'moc-focus-mode)

(defun moc-focus-toggle-invisibility ()
  (interactive)
  (moc--focus-assert-mode)
  (if buffer-invisibility-spec
      (setq buffer-invisibility-spec nil)
    (setq buffer-invisibility-spec
          moc--focus-invisibilty-spec)))

(put 'moc-focus-toggle-invisibility 'mode 'moc-focus-mode)


(defun moc-focus-kill-ring-save ()
  "Save the focused text and highlights to a playback expression."
  (interactive)
  (moc--focus-assert-mode)
  (let ((expression
         `(moc-focus
           :overlays ',moc--focus-overlay-specs
           :invisibility-spec ',moc--focus-invisibilty-spec
           :string ,moc--focus-cleaned-text
           :highlights ',moc--focus-highlights
           :occludes ',moc--focus-occludes)))
    (kill-new (prin1-to-string expression)))
  (message "saved focus to kill ring."))

(put 'moc-focus-kill-ring-save 'mode 'moc-focus-mode)

;; ** Focus Extraction & Pre-Processing

(defun moc--focus-clean-properties (text)
  "Reduce the properties for more succinct playback expressions.
When using `moc-focus-kill-ring-save', we have to save every single text
property.  Appropriate behavior for this function is to return TEXT only
with properties that will affect display.  It would be appropriate to
omit any faces that don't have a visible effect on the result.  It may
be better to configure away certain faces that are being effectively
removed by `moc-face-remap'.

Because we don't know the context of the text that is being focused, we
can't use temporary buffers and font locking to restore properties; the
text we have is likely incomplete out of context."
  (let ((dirty-props (object-intervals text))
        (clean-string (substring-no-properties text)))
    (mapc
     (lambda (interval)
       (let ((begin (pop interval))
             (end (pop interval)))
         (mapc
          (lambda (prop-name)
            (when-let* ((prop (plist-get (car interval) prop-name)))
              (put-text-property begin end prop-name prop clean-string)))
          '(face font-lock-face button invisible display))))
     dirty-props)
    clean-string))

(defun moc--focus-serialize-overlay (overlay spans)
  "Serialize OVERLAY properties for playback etc.
The overlay's start and end are translated using BEG and SPANS to ensure
that the resulting overlay information will result in an overlay that
accurately applies to the same text in the focus buffer that OVERLAY
applies to in the source buffer.

The return value is (BEG END . PROPS) where PROPS is the list returned
from `overlay-properties'.

🚧 This first pass only does basic translation without consideration for
trimming.  SPANS is just ((BEG . END)) for now."
  (let ((props (overlay-properties overlay))
        (beg (caar spans))
        clean)
    ;; TODO translates sizes beyond SPANS

    ;; An overlay beginning right on beg will start at buffer position 1, so we
    ;; have to add 1 (by subtracting -1)
    (push (max 1 (- (overlay-start overlay) beg -1)) clean)
    (push (max 1 (- (overlay-end overlay) beg -1)) clean)
    (while-let ((prop (pop props)))
      ;; TODO make "nice" properties configurable and test out line-prefix to be
      ;; sure it plays nice with our centering.
      (when (member prop '(button
                           display
                           face
                           height
                           invisible
                           line-height
                           line-prefix
                           line-spacing
                           priority
                           wrap-prefix))
        (push prop clean)
        (push (pop props) clean)))
    (nreverse clean)))

;;;###autoload
(defun moc-focus (&rest args)
  "Focus selected region.
ARGS contains the following keys:

- :overlays is a list of (BEG END . PROPS) where PROPS is returned by
  `overlay-properties'.  Each element of the list is used to rehydrate an
  overlay to recreate the capture source.
- :invisibility-spec propagates the buffer's invisibility spec
- :highlights a list of conses of BEG END that will be highlighted
- :occludes a list of conses of BEG END that will be occluded
- :string 🚧 is text to be displayed.  This key is considered least stable.  It
  will likely work in a backwards compatible way, but if it turns out to lose
  necessary information, another key could take its place.

🚧 This function and its signature are likely to evolve.  The base
interactive use case of highlighting a region is stable and very useful."
  (interactive
   (if (region-active-p)
       (let* ((region-bol (save-excursion
                            (goto-char (region-beginning))
                            (if (bolp) (point) (line-beginning-position))))
              (whitespace (string-match-p
                           "\s-+" (buffer-substring region-bol (point))))
              (beg (if rectangle-mark-mode
                       (region-beginning)
                     (if whitespace region-bol
                       (region-beginning))))
              ;; XXX this is incomplete
              ;; TODO trimming support
              (spans (list (cons beg (region-end))))
              (overlays (unless rectangle-mark-mode
                          (cl-loop for o in (overlays-in beg (region-end))
                                   when (not (eq (overlay-get o 'face)
                                                 'region))
                                   collect o)))
              (translated-overlays (mapcar (lambda (overlay)
                                             (moc--focus-serialize-overlay
                                              overlay spans))
                                           overlays)))
         (list
          :invisibility-spec buffer-invisibility-spec
          :highlights nil
          :occludes nil
          :overlays translated-overlays
          :string (if rectangle-mark-mode
                      (string-join
                       (extract-rectangle (region-beginning) (region-end))
                       "\n")
                    (buffer-substring beg (region-end)))))
     (user-error "No region selected")))
  (apply #'moc--display-fullscreen args))

;; ** Focus UI

(defun moc--focus-dispatch-screenshot-dir ()
  "Return current screenshot dir for use in info class."
  (propertize (moc--screenshot-save-dir) 'face 'transient-value))

(defun moc--focus-dispatch-clears ()
  "Return description for clearing highlights.
Used in suffix command."
  (if (or moc--focus-highlights
          moc--focus-occludes)
      (concat
       "clear "
       (propertize
        (format "%s highlights" (+ (length moc--focus-highlights)
                                   (length moc--focus-occludes)))
        'face 'transient-value))
    "clear all"))

(defun moc--focus-can-clear-p ()
  "Return non-nil if anything can be cleared."
  (or moc--focus-highlights
      moc--focus-occludes))

(defun moc--focus-cursor-toggle ()
  "Toggle hidden and subtle cursor.
When in an MC buffer, likely the user does not want to ever have a fully
visible cursor.  This command directly toggles hidden and subtle
instead."
  (interactive)
  (if moc-subtle-cursor-mode
      (moc-subtle-cursor-mode -1)
    (moc-subtle-cursor-mode 1))
  (unless moc-subtle-cursor-mode
    (moc-hide-cursor-mode 1)))

(put 'moc--focus-cursor-toggle 'mode 'moc-focus-mode)

(defun moc--focus-dispatch-overlays ()
  "Describe state of overlays.
Used in suffix."
  (format "overlays %s"
          (propertize
           (if moc--focus-overlays "on" "off")
           'face 'transient-value)))

(defun moc--focus-dispatch-invisibility ()
  "Describe state of invisibility.
Used in suffix."
  (format "invisibility %s"
          (propertize
           (if buffer-invisibility-spec "on" "off")
           'face 'transient-value)))

;;;###autoload (autoload 'moc-focus-dispatch "moc" nil t)
(transient-define-prefix moc-focus-dispatch ()
  "Transient menu for MC Focus mode."
  :transient-non-suffix t
  ;; Keep this in sync with `moc-focus-mode-map`!
  [["Highlights"
    ("l" "highlight" moc-focus-highlight)
    ("o" "occlude" moc-focus-occlude)
    ("u" "un-highlight" moc-focus-highlight-clear
     :inapt-if-not moc--focus-can-clear-p)
    ("U" moc-focus-highlight-clear
     :inapt-if-not moc--focus-can-clear-p
     :description moc--focus-dispatch-clears)]
   ["Visibiliy"
    ("v" moc-focus-toggle-overlays
     :description moc--focus-dispatch-overlays
     :inapt-if-nil moc--focus-overlay-specs)
    ("i" moc-focus-toggle-invisibility
     :description moc--focus-dispatch-invisibility
     :inapt-if-nil moc--focus-invisibilty-spec)]
   ["Face Remapping"
    ("r" "remap" moc-face-remap)
    ("c" moc-face-remap-clear
     :description moc--dispatch-faces-remapped)]
   ["Save"
    (:info #'moc--focus-dispatch-screenshot-dir)
    ("s" "screenshot" moc-screenshot)
    ("w" "kill ring" moc-focus-kill-ring-save)]]
  [["Cursor"
    (:info #'moc--dispatch-cursor-mode)
    ("." "toggle" moc--focus-cursor-toggle)]
   ["Echo area"
    ("e" moc-quiet-mode
     :description moc--dispatch-quiet-mode)]]
  ["Quit"
   ("q" "quit" moc-focus-quit)])

(put 'moc-focus-dispatch 'mode 'moc-focus-mode)

(defvar-keymap moc-focus-mode-map
  :suppress 'nodigits
  "." #'moc--focus-cursor-toggle
  "c" #'moc-face-remap-clear
  "e" #'moc-quiet-mode
  "i" #'moc-focus-toggle-invisibility
  "h" #'moc-focus-dispatch
  "l" #'moc-focus-highlight
  "o" #'moc-focus-occlude
  "q" #'moc-focus-quit
  "r" #'moc-face-remap
  "s" #'moc-screenshot
  "u" #'moc-focus-un-highlight
  "v" #'moc-focus-toggle-overlays
  "U" #'moc-focus-highlight-clear
  "w" #'moc-focus-kill-ring-save)

(define-derived-mode moc-focus-mode special-mode
  "Modal controls for focus windows."
  :interactive nil)

(provide 'moc)
;;; moc.el ends here

;; Local Variables:
;; outline-regexp: ";; \\(*+\\)"
;; End:

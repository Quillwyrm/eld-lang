
```scheme
(def osc
  (sin 220))

(def filt
  (lpf osc 1200))

(def voice
  (* 0.2 filt))

(play voice)

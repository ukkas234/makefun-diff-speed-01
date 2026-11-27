;; Myers greedy diff search + backtrack, in hand-written WebAssembly text.
;; This is the exact rule of the makefun-diff 1.0.0 reference (see solve.js):
;; furthest-reaching path per diagonal, deletion wins a deletion-vs-insertion
;; tie, no edge diagonal is pruned, equal-line runs are followed to the end.
;; Written by hand in this session; assembled with tools/wat.cjs.
;; The JavaScript wrapper (solve.js) interns lines, trims the common prefix
;; and suffix, and builds the patch text; this module does only the O(D^2)
;; search and the backtrack, where D is the edit distance.
;;
;; Memory layout (linear memory, i32 words):
;;   A ids ......... 0x00000000 (written by JS, n words)
;;   B ids ......... 0x00040000 (written by JS, m words)
;;   out runs ...... 0x00080000 (pairs of i32: kind, count; 0=keep 1=del 2=ins)
;;   seg scratch ... 0x00200000 (backtrack segments, reverse order)
;;   trace ......... 0x04000000 (flat trace, round d at offset d*(d+1)/2)
;; Memory starts at 4096 pages (256 MiB) and grows to at most 10240 (640 MiB).
;; $segBase sits at 2 MiB so `out` holds 196,608 runs — above the 120,000
;; theoretical maximum for WASM_MAX_LINES = 60000 — and can never overwrite
;; backtrack segments that the merge loop has not read yet. The 640 MiB cap
;; keeps memory.grow failing cleanly well below the 1024 MB container limit
;; instead of letting the cgroup OOM killer strike first.
;; search returns the number of runs written to $out, or -1 when the trace
;; would not fit in memory (the JS wrapper then falls back to its own search).
(module
  (memory (export "mem") 4096 10240)
  (global $traceBase i32 (i32.const 67108864))
  (global $segBase i32 (i32.const 2097152))

  (func (export "search") (param $a i32) (param $n i32) (param $b i32) (param $m i32) (param $out i32) (result i32)
    (local $d i32) (local $j i32) (local $k i32) (local $x i32) (local $y i32)
    (local $nx i32) (local $ny i32) (local $xDel i32) (local $xIns i32)
    (local $px i32) (local $pxDel i32) (local $pxIns i32) (local $delX i32) (local $insX i32)
    (local $prevOff i32) (local $curOff i32) (local $prevPtr i32) (local $curPtr i32) (local $D i32) (local $endJ i32)
    (local $segCount i32) (local $w i32) (local $r i32)
    (local $kind i32) (local $cnt i32) (local $tmp i32) (local $need i32) (local $snake i32)

    ;; ---- round 0: the seed snake on diagonal 0 ----
    (local.set $x (i32.const 0))
    (local.set $y (i32.const 0))
    (block $s0done
      (loop $s0
        (if (i32.and
              (i32.and (i32.lt_s (local.get $x) (local.get $n)) (i32.lt_s (local.get $y) (local.get $m)))
              (i32.eq
                (i32.load (i32.add (local.get $a) (i32.shl (local.get $x) (i32.const 2))))
                (i32.load (i32.add (local.get $b) (i32.shl (local.get $y) (i32.const 2))))))
          (then
            (local.set $x (i32.add (local.get $x) (i32.const 1)))
            (local.set $y (i32.add (local.get $y) (i32.const 1)))
            (br $s0)))
        (br $s0done)))
    (i32.store (global.get $traceBase) (local.get $x))
    (if (i32.and (i32.eq (local.get $x) (local.get $n)) (i32.eq (local.get $y) (local.get $m)))
      (then
        (i32.store (local.get $out) (i32.const 0))
        (i32.store offset=4 (local.get $out) (local.get $x))
        (return (i32.const 1))))

    ;; ---- forward rounds ----
    (local.set $d (i32.const 1))
    (block $found
      (loop $outer
        ;; Grow the trace region when the coming round would not fit.
        (local.set $need (i32.add (global.get $traceBase)
          (i32.shl (i32.add
            (i32.div_s (i32.mul (local.get $d) (i32.add (local.get $d) (i32.const 1))) (i32.const 2))
            (i32.add (local.get $d) (i32.const 1)))
            (i32.const 2))))
        (if (i32.gt_u (local.get $need) (i32.shl (memory.size) (i32.const 16)))
          (then
            (local.set $tmp (i32.sub (local.get $need) (i32.shl (memory.size) (i32.const 16))))
            (local.set $tmp (memory.grow (i32.shr_u (i32.add (local.get $tmp) (i32.const 65535)) (i32.const 16))))
            (if (i32.eq (local.get $tmp) (i32.const -1))
              (then (return (i32.const -1))))))
        (local.set $prevOff (i32.div_s (i32.mul (i32.sub (local.get $d) (i32.const 1)) (local.get $d)) (i32.const 2)))
        (local.set $curOff (i32.div_s (i32.mul (local.get $d) (i32.add (local.get $d) (i32.const 1))) (i32.const 2)))
        (local.set $prevPtr (i32.add (global.get $traceBase) (i32.shl (local.get $prevOff) (i32.const 2))))
        (local.set $curPtr (i32.add (global.get $traceBase) (i32.shl (local.get $curOff) (i32.const 2))))
        (local.set $j (i32.const 0))
        (local.set $k (i32.sub (i32.const 0) (local.get $d)))
        (loop $inner
          (block $step
            (local.set $xDel (i32.const -1))
            (local.set $xIns (i32.const -1))
            (if (i32.gt_s (local.get $j) (i32.const 0))
              (then
                (local.set $px (i32.load (i32.add (local.get $prevPtr) (i32.shl (i32.sub (local.get $j) (i32.const 1)) (i32.const 2)))))
                (if (i32.and (i32.ge_s (local.get $px) (i32.const 0)) (i32.lt_s (local.get $px) (local.get $n)))
                  (then (local.set $xDel (i32.add (local.get $px) (i32.const 1)))))))
            (if (i32.lt_s (local.get $j) (local.get $d))
              (then
                (local.set $px (i32.load (i32.add (local.get $prevPtr) (i32.shl (local.get $j) (i32.const 2)))))
                (if (i32.and (i32.ge_s (local.get $px) (i32.const 0)) (i32.le_s (i32.sub (local.get $px) (local.get $k)) (local.get $m)))
                  (then (local.set $xIns (local.get $px))))))
            (if (i32.ge_s (local.get $xDel) (local.get $xIns))
              (then
                (if (i32.lt_s (local.get $xDel) (i32.const 0))
                  (then
                    (i32.store (i32.add (local.get $curPtr) (i32.shl (local.get $j) (i32.const 2))) (i32.const -1))
                    (br $step))
                  (else (local.set $nx (local.get $xDel)))))
              (else (local.set $nx (local.get $xIns))))
            (local.set $ny (i32.sub (local.get $nx) (local.get $k)))
            (block $sndone
              (loop $sn
                (if (i32.and
                      (i32.and (i32.lt_s (local.get $nx) (local.get $n)) (i32.lt_s (local.get $ny) (local.get $m)))
                      (i32.eq
                        (i32.load (i32.add (local.get $a) (i32.shl (local.get $nx) (i32.const 2))))
                        (i32.load (i32.add (local.get $b) (i32.shl (local.get $ny) (i32.const 2))))))
                  (then
                    (local.set $nx (i32.add (local.get $nx) (i32.const 1)))
                    (local.set $ny (i32.add (local.get $ny) (i32.const 1)))
                    (br $sn)))
                (br $sndone)))
            (i32.store (i32.add (local.get $curPtr) (i32.shl (local.get $j) (i32.const 2))) (local.get $nx))
            (if (i32.and (i32.eq (local.get $nx) (local.get $n)) (i32.eq (local.get $ny) (local.get $m)))
              (then
                (local.set $D (local.get $d))
                (local.set $endJ (local.get $j))
                (br $found))))
          (local.set $j (i32.add (local.get $j) (i32.const 1)))
          (local.set $k (i32.add (local.get $k) (i32.const 2)))
          (br_if $inner (i32.le_s (local.get $j) (local.get $d))))
        (local.set $d (i32.add (local.get $d) (i32.const 1)))
        (br $outer)))

    ;; ---- backtrack: segments (kind, count) into $segBase, reverse order ----
    (local.set $segCount (i32.const 0))
    (local.set $j (local.get $endJ))
    (local.set $x (local.get $n))
    (local.set $y (local.get $m))
    (local.set $d (local.get $D))
    (block $backDone
      (loop $back
        (if (i32.lt_s (local.get $d) (i32.const 1)) (then (br $backDone)))
        (local.set $k (i32.sub (i32.shl (local.get $j) (i32.const 1)) (local.get $d)))
        (local.set $prevOff (i32.div_s (i32.mul (i32.sub (local.get $d) (i32.const 1)) (local.get $d)) (i32.const 2)))
        (local.set $prevPtr (i32.add (global.get $traceBase) (i32.shl (local.get $prevOff) (i32.const 2))))
        (local.set $pxDel (i32.const -1))
        (local.set $pxIns (i32.const -1))
        (if (i32.gt_s (local.get $j) (i32.const 0))
          (then (local.set $pxDel (i32.load (i32.add (local.get $prevPtr) (i32.shl (i32.sub (local.get $j) (i32.const 1)) (i32.const 2)))))))
        (if (i32.lt_s (local.get $j) (local.get $d))
          (then (local.set $pxIns (i32.load (i32.add (local.get $prevPtr) (i32.shl (local.get $j) (i32.const 2)))))))
        (local.set $delX (i32.const -1))
        (local.set $insX (i32.const -1))
        (if (i32.and (i32.ge_s (local.get $pxDel) (i32.const 0)) (i32.lt_s (local.get $pxDel) (local.get $n)))
          (then (local.set $delX (i32.add (local.get $pxDel) (i32.const 1)))))
        (if (i32.and (i32.ge_s (local.get $pxIns) (i32.const 0)) (i32.le_s (i32.sub (local.get $pxIns) (local.get $k)) (local.get $m)))
          (then (local.set $insX (local.get $pxIns))))
        (if (i32.ge_s (local.get $delX) (local.get $insX))
          (then
            (local.set $snake (i32.sub (local.get $x) (i32.add (local.get $pxDel) (i32.const 1))))
            (if (i32.gt_s (local.get $snake) (i32.const 0))
              (then
                (i32.store (i32.add (global.get $segBase) (i32.shl (local.get $segCount) (i32.const 3))) (i32.const 0))
                (i32.store offset=4 (i32.add (global.get $segBase) (i32.shl (local.get $segCount) (i32.const 3))) (local.get $snake))
                (local.set $segCount (i32.add (local.get $segCount) (i32.const 1)))))
            (i32.store (i32.add (global.get $segBase) (i32.shl (local.get $segCount) (i32.const 3))) (i32.const 1))
            (i32.store offset=4 (i32.add (global.get $segBase) (i32.shl (local.get $segCount) (i32.const 3))) (i32.const 1))
            (local.set $segCount (i32.add (local.get $segCount) (i32.const 1)))
            (local.set $x (local.get $pxDel))
            (local.set $y (i32.sub (local.get $pxDel) (i32.sub (local.get $k) (i32.const 1))))
            (local.set $j (i32.sub (local.get $j) (i32.const 1))))
          (else
            (local.set $snake (i32.sub (local.get $x) (local.get $pxIns)))
            (if (i32.gt_s (local.get $snake) (i32.const 0))
              (then
                (i32.store (i32.add (global.get $segBase) (i32.shl (local.get $segCount) (i32.const 3))) (i32.const 0))
                (i32.store offset=4 (i32.add (global.get $segBase) (i32.shl (local.get $segCount) (i32.const 3))) (local.get $snake))
                (local.set $segCount (i32.add (local.get $segCount) (i32.const 1)))))
            (i32.store (i32.add (global.get $segBase) (i32.shl (local.get $segCount) (i32.const 3))) (i32.const 2))
            (i32.store offset=4 (i32.add (global.get $segBase) (i32.shl (local.get $segCount) (i32.const 3))) (i32.const 1))
            (local.set $segCount (i32.add (local.get $segCount) (i32.const 1)))
            (local.set $x (local.get $pxIns))
            (local.set $y (i32.sub (local.get $pxIns) (i32.add (local.get $k) (i32.const 1))))))
        (local.set $d (i32.sub (local.get $d) (i32.const 1)))
        (br $back)))
    (if (i32.gt_s (local.get $x) (i32.const 0))
      (then
        (i32.store (i32.add (global.get $segBase) (i32.shl (local.get $segCount) (i32.const 3))) (i32.const 0))
        (i32.store offset=4 (i32.add (global.get $segBase) (i32.shl (local.get $segCount) (i32.const 3))) (local.get $x))
        (local.set $segCount (i32.add (local.get $segCount) (i32.const 1)))))

    ;; ---- merge the segments (read backwards = forward order) into $out ----
    (local.set $w (i32.const 0))
    (local.set $r (i32.sub (local.get $segCount) (i32.const 1)))
    (block $mergeDone
      (loop $merge
        (if (i32.lt_s (local.get $r) (i32.const 0)) (then (br $mergeDone)))
        (local.set $kind (i32.load (i32.add (global.get $segBase) (i32.shl (local.get $r) (i32.const 3)))))
        (local.set $cnt (i32.load offset=4 (i32.add (global.get $segBase) (i32.shl (local.get $r) (i32.const 3)))))
        (if (i32.and
              (i32.gt_s (local.get $w) (i32.const 0))
              (i32.eq (local.get $kind) (i32.load (i32.add (local.get $out) (i32.shl (i32.sub (local.get $w) (i32.const 1)) (i32.const 3))))))
          (then
            (i32.store offset=4
              (i32.add (local.get $out) (i32.shl (i32.sub (local.get $w) (i32.const 1)) (i32.const 3)))
              (i32.add
                (i32.load offset=4 (i32.add (local.get $out) (i32.shl (i32.sub (local.get $w) (i32.const 1)) (i32.const 3))))
                (local.get $cnt))))
          (else
            (i32.store (i32.add (local.get $out) (i32.shl (local.get $w) (i32.const 3))) (local.get $kind))
            (i32.store offset=4 (i32.add (local.get $out) (i32.shl (local.get $w) (i32.const 3))) (local.get $cnt))
            (local.set $w (i32.add (local.get $w) (i32.const 1)))))
        (local.set $r (i32.sub (local.get $r) (i32.const 1)))
        (br $merge)))
    (local.get $w))
)

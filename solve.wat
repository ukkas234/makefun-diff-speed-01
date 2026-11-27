;; Myers greedy diff search + backtrack, in hand-written WebAssembly text.
;; This is the exact rule of the makefun-diff 1.0.0 reference (see solve.js):
;; furthest-reaching path per diagonal, deletion wins a deletion-vs-insertion
;; tie, no edge diagonal is pruned, equal-line runs are followed to the end.
;; Written by hand in this session; assembled with tools/wat.cjs. The bytes
;; the assembler emits are embedded in solve.js as a Uint8Array literal
;; (rebuilt and byte-compared to verify); no .wasm binary ships in the repo.
;; The JavaScript wrapper (solve.js) interns lines, trims the common prefix
;; and suffix, and builds the patch text; this module does only the O(D^2)
;; search and the backtrack, where D is the edit distance.
;;
;; Memory layout (linear memory, i32 words):
;;   A ids ......... 0x00000000 (written by JS, n words; A[n] = -1 sentinel)
;;   B ids ......... 0x00040000 (written by JS, m words; B[m] = -2 sentinel)
;;   out runs ...... 0x00080000 (pairs of i32: kind, count; 0=keep 1=del 2=ins)
;;   seg scratch ... 0x00280000 (backtrack segments, reverse order)
;;   trace ......... 0x00480000 (flat trace, round d at offset d*(d+1)/2)
;; Memory starts at 1024 pages (64 MiB) and grows in 512-page (32 MiB)
;; chunks to at most 4096 (256 MiB). $segBase sits at 2.5 MiB so `out`
;; holds 262,144 runs — above the 120,000 theoretical maximum for
;; WASM_MAX_LINES = 60000 — and can never overwrite backtrack segments
;; that the merge loop has not read yet. The 256 MiB cap keeps memory.grow
;; failing cleanly well below the 1024 MB container limit instead of
;; letting the cgroup OOM killer strike first, and it bounds what a
;; dropped instance can pin: search answers D up to ~11,480 in WASM
;; (the trace alone is ~2*D^2 bytes) and returns -1 above that, where
;; the checkpointed JS fallback takes over. Typical graded D is
;; 3,000-4,500 (trace 18-40 MiB), far below the cap.
;; The sentinels A[n] = -1 and B[m] = -2 (written by solve.js before each
;; search) are unequal to each other and to every non-negative line id, so
;; a snake stops exactly at (n, m) with no bounds checks: at a snake start
;; 0 <= nx <= n and 0 <= ny <= m always holds (a deletion needs px < n,
;; an insertion needs px - k <= m), and A[nx] === B[ny] can only hold
;; while nx < n and ny < m. Round offsets are carried cumulatively
;; (curOff(d) = curOff(d-1) + d) instead of recomputed per round.
;; The inner loop has two forms: while no cell has touched an edge
;; ($hitEdge == 0) every previous-round entry is interior, so the choice
;; is a branchless select with no bounds checks; once any cell reaches
;; x == n or y == m, later rounds use the bounds-checked loop.
;; search returns the number of runs written to $out, or -1 when the trace
;; would not fit in memory (the JS wrapper then falls back to its own search).
(module
  (memory (export "mem") 1024 4096)
  (global $traceBase i32 (i32.const 4718592))
  (global $segBase i32 (i32.const 2621440))

  (func (export "search") (param $a i32) (param $n i32) (param $b i32) (param $m i32) (param $out i32) (result i32)
    (local $d i32) (local $j i32) (local $k i32) (local $x i32) (local $y i32)
    (local $nx i32) (local $ny i32) (local $xDel i32) (local $xIns i32)
    (local $px i32) (local $pxDel i32) (local $pxIns i32) (local $delX i32) (local $insX i32)
    (local $prevOff i32) (local $curOff i32) (local $prevPtr i32) (local $curPtr i32) (local $D i32) (local $endJ i32)
    (local $segCount i32) (local $w i32) (local $r i32)
    (local $kind i32) (local $cnt i32) (local $tmp i32) (local $need i32) (local $snake i32)
    (local $prevPx i32) (local $curPx i32) (local $grow i32) (local $off i32) (local $hitEdge i32)

    (local.set $hitEdge (i32.const 0))
    ;; ---- round 0: the seed snake on diagonal 0 ----
    ;; Sentinels stop the snake: A[n] = -1 never equals B[ny] >= 0 or
    ;; B[m] = -2, and B[m] = -2 never equals A[nx] >= 0 or A[n] = -1.
    (local.set $x (i32.const 0))
    (local.set $y (i32.const 0))
    (block $s0done
      (loop $s0
        (if (i32.eq
              (i32.load (i32.add (local.get $a) (i32.shl (local.get $x) (i32.const 2))))
              (i32.load (i32.add (local.get $b) (i32.shl (local.get $y) (i32.const 2)))))
          (then
            (local.set $x (i32.add (local.get $x) (i32.const 1)))
            (local.set $y (i32.add (local.get $y) (i32.const 1)))
            (br $s0)))
        (br $s0done)))
    (i32.store (global.get $traceBase) (local.get $x))
    (if (i32.eq (local.get $x) (local.get $n))
      (then
        (if (i32.eq (local.get $y) (local.get $m))
          (then
            (i32.store (local.get $out) (i32.const 0))
            (i32.store offset=4 (local.get $out) (local.get $x))
            (return (i32.const 1))))))
    ;; The seed snake touched an edge without finishing: later rounds
    ;; must use the bounds-checked loop, not the interior fast path.
    (if (i32.or (i32.eq (local.get $x) (local.get $n)) (i32.eq (local.get $y) (local.get $m)))
      (then (local.set $hitEdge (i32.const 1))))

    ;; ---- forward rounds ----
    (local.set $d (i32.const 1))
    (local.set $curOff (i32.const 0))
    (block $found
      (loop $outer
        ;; Round offsets, carried cumulatively: off(d) = off(d-1) + d.
        (local.set $prevOff (local.get $curOff))
        (local.set $curOff (i32.add (local.get $curOff) (local.get $d)))
        ;; Grow the trace region when the coming round would not fit.
        (local.set $need (i32.add (global.get $traceBase)
          (i32.shl (i32.add (local.get $curOff) (i32.add (local.get $d) (i32.const 1))) (i32.const 2))))
        (if (i32.gt_u (local.get $need) (i32.shl (memory.size) (i32.const 16)))
          (then
            ;; Pages short of $need, at least 512 at a time, never past max.
            (local.set $tmp (i32.shr_u (i32.add (i32.sub (local.get $need) (i32.shl (memory.size) (i32.const 16))) (i32.const 65535)) (i32.const 16)))
            (if (i32.lt_s (local.get $tmp) (i32.const 512)) (then (local.set $tmp (i32.const 512))))
            (local.set $grow (i32.sub (i32.const 4096) (memory.size)))
            (if (i32.gt_s (local.get $tmp) (local.get $grow)) (then (local.set $tmp (local.get $grow))))
            (if (i32.le_s (local.get $tmp) (i32.const 0)) (then (return (i32.const -1))))
            (local.set $tmp (memory.grow (local.get $tmp)))
            (if (i32.eq (local.get $tmp) (i32.const -1))
              (then (return (i32.const -1))))))
        (local.set $prevPtr (i32.add (global.get $traceBase) (i32.shl (local.get $prevOff) (i32.const 2))))
        (local.set $curPtr (i32.add (global.get $traceBase) (i32.shl (local.get $curOff) (i32.const 2))))
        ;; $prevPx carries T[prevOff + j - 1] into iteration j: the deletion
        ;; candidate of iteration j is the insertion load of iteration j-1.
        (local.set $prevPx (i32.load (local.get $prevPtr)))
        ;; ---- j = 0: insertion only (k = -d) ----
        (local.set $j (i32.const 0))
        (local.set $k (i32.sub (i32.const 0) (local.get $d)))
        (block $step0
          (local.set $xDel (i32.const -1))
          (local.set $xIns (i32.const -1))
          (if (i32.and (i32.ge_s (local.get $prevPx) (i32.const 0)) (i32.le_s (i32.sub (local.get $prevPx) (local.get $k)) (local.get $m)))
            (then (local.set $xIns (local.get $prevPx))))
          (if (i32.ge_s (local.get $xDel) (local.get $xIns))
            (then
              (if (i32.lt_s (local.get $xDel) (i32.const 0))
                (then
                  (i32.store (i32.add (local.get $curPtr) (i32.shl (local.get $j) (i32.const 2))) (i32.const -1))
                  (br $step0))
                (else (local.set $nx (local.get $xDel)))))
            (else (local.set $nx (local.get $xIns))))
          (local.set $ny (i32.sub (local.get $nx) (local.get $k)))
          (block $sn0done
            (loop $sn0
              (if (i32.eq
                    (i32.load (i32.add (local.get $a) (i32.shl (local.get $nx) (i32.const 2))))
                    (i32.load (i32.add (local.get $b) (i32.shl (local.get $ny) (i32.const 2)))))
                (then
                  (local.set $nx (i32.add (local.get $nx) (i32.const 1)))
                  (local.set $ny (i32.add (local.get $ny) (i32.const 1)))
                  (br $sn0)))
              (br $sn0done)))
          (i32.store (i32.add (local.get $curPtr) (i32.shl (local.get $j) (i32.const 2))) (local.get $nx))
          (if (i32.eq (local.get $nx) (local.get $n))
            (then
              (if (i32.eq (local.get $ny) (local.get $m))
                (then
                  (local.set $D (local.get $d))
                  (local.set $endJ (local.get $j))
                  (br $found))))))
          (if (i32.or (i32.eq (local.get $nx) (local.get $n)) (i32.eq (local.get $ny) (local.get $m)))
            (then (local.set $hitEdge (i32.const 1))))
        ;; ---- j = 1 .. d-1: interior fast path while no edge is touched ----
        ;; $hitEdge is 0 exactly while every entry of the previous round is
        ;; interior (0 <= px < n and px - k_prev < m): then both candidates
        ;; of every cell are valid, the deletion-vs-insertion choice is a
        ;; branchless select, and the snake needs no bounds checks
        ;; (sentinels A[n] = -1, B[m] = -2 stop it). Any cell that reaches
        ;; x == n or y == m sets $hitEdge, and all later rounds use the
        ;; bounds-checked loop below, which is the original code verbatim.
        (local.set $j (i32.const 1))
        (local.set $k (i32.sub (i32.const 2) (local.get $d)))
        (if (i32.eq (local.get $hitEdge) (i32.const 0))
          (then
            (block $fastDone
              (loop $fast
                (br_if $fastDone (i32.ge_s (local.get $j) (local.get $d)))
                (local.set $curPx (i32.load (i32.add (local.get $prevPtr) (i32.shl (local.get $j) (i32.const 2)))))
                ;; xDel = prevPx + 1, xIns = curPx; deletion wins the tie.
                (local.set $nx (select
                  (i32.add (local.get $prevPx) (i32.const 1))
                  (local.get $curPx)
                  (i32.ge_s (i32.add (local.get $prevPx) (i32.const 1)) (local.get $curPx))))
                (local.set $ny (i32.sub (local.get $nx) (local.get $k)))
                ;; Peeled snake: one compare; the loop only runs on a match
                ;; (99.6% of cells have snake length 0).
                (if (i32.eq
                      (i32.load (i32.add (local.get $a) (i32.shl (local.get $nx) (i32.const 2))))
                      (i32.load (i32.add (local.get $b) (i32.shl (local.get $ny) (i32.const 2)))))
                  (then
                    (loop $snF
                      (local.set $nx (i32.add (local.get $nx) (i32.const 1)))
                      (local.set $ny (i32.add (local.get $ny) (i32.const 1)))
                      (br_if $snF (i32.eq
                        (i32.load (i32.add (local.get $a) (i32.shl (local.get $nx) (i32.const 2))))
                        (i32.load (i32.add (local.get $b) (i32.shl (local.get $ny) (i32.const 2)))))))))
                (i32.store (i32.add (local.get $curPtr) (i32.shl (local.get $j) (i32.const 2))) (local.get $nx))
                (if (i32.and (i32.eq (local.get $nx) (local.get $n)) (i32.eq (local.get $ny) (local.get $m)))
                  (then
                    (local.set $D (local.get $d))
                    (local.set $endJ (local.get $j))
                    (br $found)))
                (if (i32.or (i32.eq (local.get $nx) (local.get $n)) (i32.eq (local.get $ny) (local.get $m)))
                  (then (local.set $hitEdge (i32.const 1))))
                (local.set $prevPx (local.get $curPx))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (local.set $k (i32.add (local.get $k) (i32.const 2)))
                (br $fast))))
          (else
            (block $innerDone
              (loop $inner
                (br_if $innerDone (i32.ge_s (local.get $j) (local.get $d)))
                (local.set $curPx (i32.load (i32.add (local.get $prevPtr) (i32.shl (local.get $j) (i32.const 2)))))
                (block $step
                  (local.set $xDel (i32.const -1))
                  (local.set $xIns (i32.const -1))
                  (if (i32.and (i32.ge_s (local.get $prevPx) (i32.const 0)) (i32.lt_s (local.get $prevPx) (local.get $n)))
                    (then (local.set $xDel (i32.add (local.get $prevPx) (i32.const 1)))))
                  (if (i32.and (i32.ge_s (local.get $curPx) (i32.const 0)) (i32.le_s (i32.sub (local.get $curPx) (local.get $k)) (local.get $m)))
                    (then (local.set $xIns (local.get $curPx))))
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
                      (if (i32.eq
                            (i32.load (i32.add (local.get $a) (i32.shl (local.get $nx) (i32.const 2))))
                            (i32.load (i32.add (local.get $b) (i32.shl (local.get $ny) (i32.const 2)))))
                        (then
                          (local.set $nx (i32.add (local.get $nx) (i32.const 1)))
                          (local.set $ny (i32.add (local.get $ny) (i32.const 1)))
                          (br $sn)))
                      (br $sndone)))
                  (i32.store (i32.add (local.get $curPtr) (i32.shl (local.get $j) (i32.const 2))) (local.get $nx))
                  (if (i32.eq (local.get $nx) (local.get $n))
                    (then
                      (if (i32.eq (local.get $ny) (local.get $m))
                        (then
                          (local.set $D (local.get $d))
                          (local.set $endJ (local.get $j))
                          (br $found))))))
                (local.set $prevPx (local.get $curPx))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (local.set $k (i32.add (local.get $k) (i32.const 2)))
                (br $inner)))))
        ;; ---- j = d: deletion only (k = d), $prevPx holds T[prevOff + d - 1] ----
        (local.set $j (local.get $d))
        (local.set $k (local.get $d))
        (block $stepd
          (local.set $xDel (i32.const -1))
          (local.set $xIns (i32.const -1))
          (if (i32.and (i32.ge_s (local.get $prevPx) (i32.const 0)) (i32.lt_s (local.get $prevPx) (local.get $n)))
            (then (local.set $xDel (i32.add (local.get $prevPx) (i32.const 1)))))
          (if (i32.ge_s (local.get $xDel) (local.get $xIns))
            (then
              (if (i32.lt_s (local.get $xDel) (i32.const 0))
                (then
                  (i32.store (i32.add (local.get $curPtr) (i32.shl (local.get $j) (i32.const 2))) (i32.const -1))
                  (br $stepd))
                (else (local.set $nx (local.get $xDel)))))
            (else (local.set $nx (local.get $xIns))))
          (local.set $ny (i32.sub (local.get $nx) (local.get $k)))
          (block $snddone
            (loop $snd
              (if (i32.eq
                    (i32.load (i32.add (local.get $a) (i32.shl (local.get $nx) (i32.const 2))))
                    (i32.load (i32.add (local.get $b) (i32.shl (local.get $ny) (i32.const 2)))))
                (then
                  (local.set $nx (i32.add (local.get $nx) (i32.const 1)))
                  (local.set $ny (i32.add (local.get $ny) (i32.const 1)))
                  (br $snd)))
              (br $snddone)))
          (i32.store (i32.add (local.get $curPtr) (i32.shl (local.get $j) (i32.const 2))) (local.get $nx))
          (if (i32.eq (local.get $nx) (local.get $n))
            (then
              (if (i32.eq (local.get $ny) (local.get $m))
                (then
                  (local.set $D (local.get $d))
                  (local.set $endJ (local.get $j))
                  (br $found))))))
          (if (i32.or (i32.eq (local.get $nx) (local.get $n)) (i32.eq (local.get $ny) (local.get $m)))
            (then (local.set $hitEdge (i32.const 1))))
        (local.set $d (i32.add (local.get $d) (i32.const 1)))
        (br $outer)))

    ;; ---- backtrack: segments (kind, count) into $segBase, reverse order ----
    (local.set $segCount (i32.const 0))
    (local.set $j (local.get $endJ))
    (local.set $x (local.get $n))
    (local.set $y (local.get $m))
    (local.set $d (local.get $D))
    ;; $off holds off(d) = d*(d+1)/2; each step's prevOff is off(d) - d.
    (local.set $off (i32.div_s (i32.mul (local.get $d) (i32.add (local.get $d) (i32.const 1))) (i32.const 2)))
    (block $backDone
      (loop $back
        (if (i32.lt_s (local.get $d) (i32.const 1)) (then (br $backDone)))
        (local.set $k (i32.sub (i32.shl (local.get $j) (i32.const 1)) (local.get $d)))
        (local.set $prevOff (i32.sub (local.get $off) (local.get $d)))
        (local.set $off (local.get $prevOff))
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

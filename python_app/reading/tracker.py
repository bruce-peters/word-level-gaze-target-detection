"""Reading-position tracking state machine.

Direct port of app.js sections 2 and 4-7: Z-cut line switching, word-within-line
assignment, and huge-jump relocation to the nearest sentence start. This module
is UI-agnostic -- it operates purely on px coordinates from a LayoutModel
(reading/layout.py) and exposes a `Tracker.process_gaze(gx, gy, now_ms)` call
that mirrors the line/word-assignment half of app.js's onGaze(). The caller
(ui/app_window.py) is responsible for turning the resulting state into pixel
highlights, matching how app.js's updateHighlights() toggled CSS classes.
"""

from dataclasses import dataclass, field


# "How many sigmas is HUGE": bigger = harder to trigger a relocation.
JUMP_K = 4

# thresholds as fractions of line width. Paper uses 20% borders; relaxed to
# 30%/70% because webcam gaze compresses toward center and often never reaches
# the outer 20%, which would stop the Z-cut from ever firing.
Z_LEFT = 0.3
Z_RIGHT = 0.7
Z_COOLDOWN_MS = 500

HUGE_JUMP_SUSTAIN_MS = 500  # deviation must hold this long to count
HUGE_JUMP_COOLDOWN_MS = 900  # settle time after a relocation (no re-trigger)
EMA_ALPHA = 0.25  # gaze smoothing (lower = smoother / more lag)


def clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


@dataclass
class ZcutDiag:
    norm_x: float = 0.0
    reach: float = 0.0
    reason: str = "-"


@dataclass
class HugeJumpState:
    over_ms: float = 0.0
    last_ts: float = 0.0
    cooldown_until: float = 0.0


@dataclass
class HugeDbg:
    dist: float = 0.0
    thresh: float = 0.0


@dataclass
class TrackState:
    tracking: bool = False
    calibrated: bool = False
    current_line: int = 0
    current_word_id: int | None = None
    max_order_reached: int = -1

    last_norm_x: float = 0.5
    max_norm_x_seen: float = 0.0
    zcut_fired_at: float = 0.0

    zcut_diag: ZcutDiag = field(default_factory=ZcutDiag)
    line_advanced_by: str = "-"  # "zcut" | "huge-jump" | "forced" | "-"

    measured_err_px: float | None = None
    calib_std_px: float | None = None
    gaze_ema: tuple | None = None  # (x, y)
    huge_jump: HugeJumpState = field(default_factory=HugeJumpState)
    huge_dbg: HugeDbg = field(default_factory=HugeDbg)


class Tracker:
    def __init__(self, layout):
        self.layout = layout  # reading.layout.LayoutModel
        self.state = TrackState()
        self._prev_line = -1
        self._prev_word = None
        self.zcut_just_fired = False

    # ---- line assignment (Z-cut) ------------------------------------
    def assign_line(self, gx, now_ms):
        """Decide the current line during linear reading. Returns True if a
        Z-cut (return sweep) just fired."""
        st = self.state
        zcut = False
        if not (0 <= st.current_line < len(self.layout.lines)):
            return False
        line = self.layout.lines[st.current_line]

        norm_x = clamp((gx - line.x_min) / max(1.0, line.width), 0, 1)
        cooled = now_ms - st.zcut_fired_at > Z_COOLDOWN_MS

        if (
            cooled
            and st.max_norm_x_seen > Z_RIGHT
            and norm_x < Z_LEFT
            and st.current_line < len(self.layout.lines) - 1
        ):
            st.current_line += 1
            st.max_norm_x_seen = 0.0
            st.zcut_fired_at = now_ms
            st.line_advanced_by = "zcut"
            zcut = True
        else:
            st.max_norm_x_seen = max(st.max_norm_x_seen, norm_x)

        self._record_zcut_diag(norm_x, now_ms)
        st.last_norm_x = norm_x
        return zcut

    def _record_zcut_diag(self, norm_x, now_ms):
        st = self.state
        reach = st.max_norm_x_seen
        if st.current_line >= len(self.layout.lines) - 1:
            reason = "last line"
        elif now_ms - st.zcut_fired_at <= Z_COOLDOWN_MS:
            reason = "cooldown"
        elif reach <= Z_RIGHT:
            reason = f"reach {reach:.2f} < {Z_RIGHT}, read righter"
        elif norm_x >= Z_LEFT:
            reason = f"armed, awaiting return (x={norm_x:.2f})"
        else:
            reason = "ready"
        st.zcut_diag = ZcutDiag(norm_x=norm_x, reach=reach, reason=reason)

    def estimate_line_gap(self):
        lines = self.layout.lines
        if len(lines) < 2:
            return 60.0
        gaps = sorted(lines[i].y_center - lines[i - 1].y_center for i in range(1, len(lines)))
        return gaps[len(gaps) // 2] or 60.0

    # ---- word-within-line (best-effort) ------------------------------
    def assign_word(self, gx):
        st = self.state
        if not (0 <= st.current_line < len(self.layout.lines)):
            return None
        line = self.layout.lines[st.current_line]
        best = None
        best_d = float("inf")
        for wid in line.word_ids:
            w = self.layout.words[wid]
            if w.x_start <= gx <= w.x_end:
                return wid
            d = w.x_start - gx if gx < w.x_start else gx - w.x_end
            if d < best_d:
                best_d = d
                best = wid
        return best

    # ---- huge-jump relocation -----------------------------------------
    def jump_sigma(self):
        st = self.state
        gap = self.estimate_line_gap()
        s = st.calib_std_px or st.measured_err_px or gap * 0.6 or 40.0
        return max(s, gap * 1.5)

    def detect_huge_jump(self, gx, gy, now_ms):
        st = self.state
        if st.gaze_ema is None:
            st.gaze_ema = (gx, gy)
        else:
            ex, ey = st.gaze_ema
            st.gaze_ema = (
                EMA_ALPHA * gx + (1 - EMA_ALPHA) * ex,
                EMA_ALPHA * gy + (1 - EMA_ALPHA) * ey,
            )
        if not (0 <= st.current_line < len(self.layout.lines)):
            return False
        cur = self.layout.lines[st.current_line]

        thresh = JUMP_K * self.jump_sigma()
        dist = abs(st.gaze_ema[1] - cur.y_center)
        st.huge_dbg = HugeDbg(dist=dist, thresh=thresh)

        hj = st.huge_jump
        dt = clamp(now_ms - hj.last_ts, 0, 500) if hj.last_ts else 0
        hj.last_ts = now_ms
        if hj.cooldown_until and now_ms < hj.cooldown_until:
            hj.over_ms = 0.0
            return False
        if dist > thresh:
            hj.over_ms += dt
            if hj.over_ms >= HUGE_JUMP_SUSTAIN_MS:
                return True
        else:
            hj.over_ms = 0.0
        return False

    def relocate_to_nearest_punctuation(self, px, py, now_ms):
        st = self.state
        best = None
        best_d = float("inf")
        for s in self.layout.sentences:
            w = self.layout.words[s.start_word_id]
            cx = (w.x_start + w.x_end) / 2
            d = ((cx - px) ** 2 + (w.y_center - py) ** 2) ** 0.5
            if d < best_d:
                best_d = d
                best = s
        if best is None:
            return None
        w = self.layout.words[best.start_word_id]
        st.current_line = w.line_index
        st.current_word_id = w.id
        st.max_norm_x_seen = 0.0
        st.line_advanced_by = "huge-jump"
        st.huge_jump.over_ms = 0.0
        st.huge_jump.cooldown_until = now_ms + HUGE_JUMP_COOLDOWN_MS
        st.gaze_ema = (px, w.y_center)
        if w.order_index > st.max_order_reached:
            st.max_order_reached = w.order_index
        self._update_highlights(w.id)
        return w

    def force_relocate(self, word_id, now_ms):
        """Manual override (double-click a word)."""
        st = self.state
        w = self.layout.words[word_id]
        st.current_line = w.line_index
        st.current_word_id = word_id
        st.max_norm_x_seen = 0.0
        st.huge_jump.over_ms = 0.0
        st.huge_jump.cooldown_until = now_ms + HUGE_JUMP_COOLDOWN_MS
        st.gaze_ema = ((w.x_start + w.x_end) / 2, w.y_center)
        if w.order_index > st.max_order_reached:
            st.max_order_reached = w.order_index
        st.line_advanced_by = "forced"
        self._update_highlights(word_id)
        return w

    # ---- highlighting bookkeeping ---------------------------------------
    def _update_highlights(self, new_word_id):
        st = self.state
        if new_word_id is not None:
            w = self.layout.words[new_word_id]
            if w.order_index > st.max_order_reached:
                st.max_order_reached = w.order_index

    def line_word_changed(self):
        """Returns (line_changed, word_changed, prev_line, prev_word) and updates
        internal prev pointers -- mirrors app.js's module-level prevLine/prevWord
        diffing so the UI only touches canvas items that actually changed."""
        st = self.state
        line_changed = st.current_line != self._prev_line
        word_changed = st.current_word_id != self._prev_word
        prev_line, prev_word = self._prev_line, self._prev_word
        if line_changed:
            self._prev_line = st.current_line
        if word_changed:
            self._prev_word = st.current_word_id
        return line_changed, word_changed, prev_line, prev_word

    # ---- top-level per-frame update --------------------------------------
    def process_gaze(self, gx, gy, now_ms):
        """Equivalent of the line-assignment half of app.js onGaze(): given a
        filtered/predicted gaze point in canvas coords, update tracking state.
        Returns True if a Z-cut fired this frame (for HUD flash)."""
        st = self.state
        self.zcut_just_fired = False
        if self.detect_huge_jump(gx, gy, now_ms):
            w = self.relocate_to_nearest_punctuation(*st.gaze_ema, now_ms=now_ms)
            return False
        zcut = self.assign_line(gx, now_ms)
        word_id = self.assign_word(gx)
        st.current_word_id = word_id
        self._update_highlights(word_id)
        self.zcut_just_fired = zcut
        return zcut

    # ---- session lifecycle -------------------------------------------
    def start_tracking(self):
        st = self.state
        st.tracking = True
        st.current_line = 0
        st.current_word_id = None
        st.max_order_reached = -1
        st.max_norm_x_seen = 0.0
        st.zcut_fired_at = 0.0
        st.huge_jump = HugeJumpState()
        st.gaze_ema = None
        st.line_advanced_by = "-"
        self._prev_line = -1
        self._prev_word = None

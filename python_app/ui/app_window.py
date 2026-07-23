"""Main Tk window: top bar, passage canvas, gaze dots, HUD, overlay wiring.

Ported from index.html's markup + the DOM-manipulation half of app.js
(sections 3, 7, 9-11b). Coordinate handling mirrors app.js's viewport vs.
document distinction: the gaze regression (gaze/calibration.py) predicts
*viewport-relative* points (same frame the calibration overlay's dot
coordinates are recorded in), which are converted to canvas/content
coordinates with `canvas.canvasx()/canvasy()` before being handed to the
tracker -- the direct equivalent of app.js's `calX = vx + window.scrollX`.
"""

import time
import tkinter as tk
import tkinter.font as tkfont
import tkinter.messagebox

from gaze.calibration import Calibrator, GazeFilter
from reading.layout import LayoutModel
from reading.tracker import Tracker
from ui.hud import Hud
from ui.overlays import AccuracyOverlay, CalibrationOverlay, SettingsOverlay, WelcomeOverlay

LINE_BG = "#1e293b"
WORD_BG = "#f59e0b"
WORD_FG = "#111318"
DEFAULT_FG = "#e5e7eb"
RELOC_FLASH = "#3b82f6"
ACCURACY_SAMPLE_MS = 3000
POLL_MS = 16


class AppWindow:
    def __init__(self, root, gaze_source, list_cameras=None, on_camera_change=None):
        self.root = root
        self.gaze_source = gaze_source
        self.list_cameras = list_cameras or (lambda: [0])
        self.on_camera_change = on_camera_change or (lambda idx: None)

        self.font = tkfont.Font(family="Georgia", size=48)
        self._build_ui()

        self.layout = LayoutModel(self.canvas, self.font)
        self.tracker = Tracker(self.layout)
        self.gaze_filter = GazeFilter()
        self.calibrator = Calibrator()

        self.raw_dot_visible = True
        self.cal_dot_visible = True
        self.raw_dot_id = None
        self.cal_dot_id = None
        self._line_word_rects_hidden = set()

        self._accuracy_active = False
        self._accuracy_samples = []
        self._last_pitch_yaw = None
        self._gaze_error_shown = False

        self.canvas.bind("<Configure>", self._on_configure)
        self.canvas.bind("<Double-Button-1>", self._on_double_click)

        self.root.after(300, self._rebuild_layout)
        self.root.after(POLL_MS, self._poll_gaze)

    # ---------------------------------------------------------------- UI
    def _build_ui(self):
        self.root.configure(bg="#0b0d12")

        topbar = tk.Frame(self.root, bg="#111318", height=48)
        topbar.pack(side="top", fill="x")

        tk.Label(topbar, text="Word Gaze Tracker", fg="#f3f4f6", bg="#111318",
                  font=("Segoe UI", 11, "bold")).pack(side="left", padx=10)

        self.btn_reset = tk.Button(topbar, text="Reset tracking", command=self.on_reset_clicked,
                                     bg="#2563eb", fg="white", bd=0, padx=8, pady=4)
        self.btn_reset.pack(side="left", padx=4, pady=6)
        self.btn_recalibrate = tk.Button(topbar, text="Recalibrate", command=self.begin_calibration,
                                           bg="#374151", fg="white", bd=0, padx=8, pady=4)
        self.btn_recalibrate.pack(side="left", padx=4, pady=6)
        self.btn_settings = tk.Button(topbar, text="Settings", command=self.open_settings,
                                        bg="#374151", fg="white", bd=0, padx=8, pady=4)
        self.btn_settings.pack(side="left", padx=4, pady=6)

        self.var_raw = tk.BooleanVar(value=True)
        self.var_cal = tk.BooleanVar(value=True)
        self.var_cam = tk.BooleanVar(value=True)
        self.var_hud = tk.BooleanVar(value=True)
        for text, var, cmd in (
            ("raw dot", self.var_raw, self._toggle_raw_dot),
            ("calibrated dot", self.var_cal, self._toggle_cal_dot),
            ("camera", self.var_cam, self._toggle_camera),
            ("debug HUD", self.var_hud, self._toggle_hud),
        ):
            tk.Checkbutton(topbar, text=text, variable=var, command=cmd,
                            fg="#cbd5e1", bg="#111318", selectcolor="#111318",
                            activebackground="#111318").pack(side="left", padx=4)

        tk.Label(topbar, text="font", fg="#cbd5e1", bg="#111318").pack(side="left", padx=(12, 2))
        self.font_scale = tk.Scale(topbar, from_=24, to=140, orient="horizontal",
                                     length=140, showvalue=False, bg="#111318", fg="#cbd5e1",
                                     troughcolor="#1f2937", highlightthickness=0,
                                     command=self._on_font_change)
        self.font_scale.set(48)
        self.font_scale.pack(side="left")
        self.font_label = tk.Label(topbar, text="48px", fg="#cbd5e1", bg="#111318")
        self.font_label.pack(side="left", padx=(4, 10))

        self.stage = tk.Frame(self.root, bg="#0b0d12")
        self.stage.pack(side="top", fill="both", expand=True)

        self.canvas = tk.Canvas(self.stage, bg="#0b0d12", highlightthickness=0)
        self.vscroll = tk.Scrollbar(self.stage, orient="vertical", command=self._on_scroll)
        self.canvas.configure(yscrollcommand=self.vscroll.set)
        self.canvas.pack(side="left", fill="both", expand=True)
        self.vscroll.pack(side="right", fill="y")

        self.welcome_overlay = WelcomeOverlay(self.stage, on_start=self._on_welcome_start)
        self.calib_overlay = CalibrationOverlay(
            self.stage, on_click=self._on_calib_click, on_done=self._on_calib_done,
            on_cancel=self._on_calib_cancel,
        )
        self.accuracy_overlay = AccuracyOverlay(self.stage, on_done=self._on_accuracy_done)
        self.settings_overlay = SettingsOverlay(
            self.stage, list_cameras=self.list_cameras, on_select=self._on_camera_select,
            on_close=lambda: self.settings_overlay.hide(),
        )

        self.hud = Hud(self.stage, on_close=lambda: self._set_hud_visible(False))
        self.hud.place(relx=1.0, rely=1.0, x=-12, y=-12, anchor="se")

        self.welcome_overlay.show()

    # ------------------------------------------------------------ layout
    def _rebuild_layout(self):
        width = self.canvas.winfo_width()
        if width <= 1:
            self.root.after(100, self._rebuild_layout)
            return
        self.layout.build(width)
        total_h = max(
            self.canvas.winfo_height(),
            int(self.layout.lines[-1].y_center + 200) if self.layout.lines else 0,
        )
        self.canvas.configure(scrollregion=(0, 0, width, total_h))
        self.raw_dot_id = None
        self.cal_dot_id = None
        self._set_hud_text("state", self.hud.vars["state"].get())
        if self.tracker.state.tracking:
            self.tracker._prev_line = -1
            self.tracker._prev_word = None
            self._apply_highlights(force=True)

    def _on_configure(self, _event):
        self._rebuild_layout()

    def _on_scroll(self, *args):
        self.canvas.yview(*args)
        self._reseed_after_scroll()

    def _reseed_after_scroll(self):
        self.tracker.state.gaze_ema = None
        self.tracker.state.huge_jump.over_ms = 0.0
        self.tracker.state.huge_jump.cooldown_until = time.perf_counter() * 1000 + 900

    def _on_font_change(self, value):
        px = int(float(value))
        self.font.configure(size=px)
        self.font_label.config(text=f"{px}px")
        self._rebuild_layout()

    # -------------------------------------------------------- highlights
    def _apply_highlights(self, force=False):
        st = self.tracker.state
        line_changed, word_changed, prev_line, prev_word = self.tracker.line_word_changed()
        if force:
            line_changed = word_changed = True
            prev_line, prev_word = None, None

        if line_changed:
            if prev_line is not None and 0 <= prev_line < len(self.layout.lines):
                for wid in self.layout.lines[prev_line].word_ids:
                    self._paint_word(wid, None)
            if 0 <= st.current_line < len(self.layout.lines):
                for wid in self.layout.lines[st.current_line].word_ids:
                    self._paint_word(wid, "line")

        if word_changed:
            if prev_word is not None:
                w = self.layout.words[prev_word]
                self._paint_word(prev_word, "line" if w.line_index == st.current_line else None)
            if st.current_word_id is not None:
                self._paint_word(st.current_word_id, "word")

    def _paint_word(self, word_id, level):
        if not (0 <= word_id < len(self.layout.words)):
            return
        w = self.layout.words[word_id]
        if level == "word":
            self.canvas.itemconfig(w.rect_id, fill=WORD_BG)
            self.canvas.itemconfig(w.item_id, fill=WORD_FG)
        elif level == "line":
            self.canvas.itemconfig(w.rect_id, fill=LINE_BG)
            self.canvas.itemconfig(w.item_id, fill=DEFAULT_FG)
        else:
            self.canvas.itemconfig(w.rect_id, fill="")
            self.canvas.itemconfig(w.item_id, fill=DEFAULT_FG)

    def _flash_relocation(self, word_id):
        w = self.layout.words[word_id]
        self.canvas.itemconfig(w.rect_id, fill=RELOC_FLASH)

        def revert():
            st = self.tracker.state
            level = "word" if st.current_word_id == word_id else (
                "line" if w.line_index == st.current_line else None
            )
            self._paint_word(word_id, level)

        self.root.after(900, revert)

    def _clear_all_highlights(self):
        for w in self.layout.words:
            self.canvas.itemconfig(w.rect_id, fill="")
            self.canvas.itemconfig(w.item_id, fill=DEFAULT_FG)

    # ------------------------------------------------------------- dots
    def _draw_dot(self, kind, x, y):
        color = "#ef4444" if kind == "raw" else "#22c55e"
        attr = "raw_dot_id" if kind == "raw" else "cal_dot_id"
        item = getattr(self, attr)
        if item is None:
            item = self.canvas.create_oval(x - 6, y - 6, x + 6, y + 6, fill=color,
                                             outline="white", width=1, tags=("dot",))
            setattr(self, attr, item)
        else:
            self.canvas.coords(item, x - 6, y - 6, x + 6, y + 6)
        self.canvas.tag_raise(item)
        visible = self.raw_dot_visible if kind == "raw" else self.cal_dot_visible
        self.canvas.itemconfig(item, state="normal" if visible else "hidden")

    # ---------------------------------------------------------- toggles
    def _toggle_raw_dot(self):
        self.raw_dot_visible = self.var_raw.get()
        if self.raw_dot_id is not None:
            self.canvas.itemconfig(self.raw_dot_id, state="normal" if self.raw_dot_visible else "hidden")

    def _toggle_cal_dot(self):
        self.cal_dot_visible = self.var_cal.get()
        if self.cal_dot_id is not None:
            self.canvas.itemconfig(self.cal_dot_id, state="normal" if self.cal_dot_visible else "hidden")

    def _toggle_camera(self):
        pass  # camera preview widget is optional; hook left for main.py to extend

    def _toggle_hud(self):
        self._set_hud_visible(self.var_hud.get())

    def _set_hud_visible(self, v):
        self.var_hud.set(v)
        if v:
            self.hud.place(relx=1.0, rely=1.0, x=-12, y=-12, anchor="se")
        else:
            self.hud.hide()

    # -------------------------------------------------------- HUD text
    def _set_hud_text(self, key, value):
        self.hud.set(key, value)

    # ---------------------------------------------------- calibration
    def _on_welcome_start(self):
        self.welcome_overlay.hide()
        self.begin_calibration()

    def begin_calibration(self):
        self._gaze_error_shown = False
        self.gaze_source.start()
        self.calibrator.clear()
        self._set_hud_text("state", "calibrating")
        self.calib_overlay.show()

    def _on_calib_click(self, idx, x, y):
        if self._last_pitch_yaw is None:
            return
        pitch, yaw = self._last_pitch_yaw
        self.calibrator.add_sample(pitch, yaw, x, y)

    def _on_calib_done(self):
        self.calib_overlay.hide()
        try:
            self.calibrator.fit()
        except ValueError:
            self._set_hud_text("state", "calibration failed, retry")
            self.calib_overlay.show()
            return
        self._run_accuracy_check()

    def _on_calib_cancel(self):
        self.calib_overlay.hide()
        self._set_hud_text("state", "idle")

    def _run_accuracy_check(self):
        self.accuracy_overlay.show()
        self.accuracy_overlay.set_result("measuring... keep staring at the dot", ready=False)
        self._accuracy_samples = []
        self._accuracy_active = True
        self.root.after(ACCURACY_SAMPLE_MS, self._finish_accuracy_check)

    def _finish_accuracy_check(self):
        self._accuracy_active = False
        samples = self._accuracy_samples
        tx, ty = self.accuracy_overlay.dot_center()
        if len(samples) < 5:
            self.accuracy_overlay.set_result(
                "No gaze samples. Check camera permission & lighting.", ready=True
            )
            return
        mean_x = sum(s[0] for s in samples) / len(samples)
        mean_y = sum(s[1] for s in samples) / len(samples)
        err_px = ((mean_x - tx) ** 2 + (mean_y - ty) ** 2) ** 0.5
        var_sum = sum((s[0] - mean_x) ** 2 + (s[1] - mean_y) ** 2 for s in samples)
        std_px = (var_sum / len(samples)) ** 0.5
        self.tracker.state.calib_std_px = std_px
        self.tracker.state.measured_err_px = err_px
        gap = self.tracker.estimate_line_gap()
        verdict = (
            "good enough for line-level" if err_px < gap else
            "usable, expect some drift" if err_px < gap * 2 else
            "coarse. Recalibrate or improve your lighting."
        )
        self.accuracy_overlay.set_result(
            f"Mean error ≈ {err_px:.0f}px, noise σ ≈ {std_px:.0f}px "
            f"(line gap ≈ {gap:.0f}px). {verdict}",
            ready=True,
        )

    def _on_accuracy_done(self):
        self.accuracy_overlay.hide()
        self.tracker.state.calibrated = True
        self.start_tracking()

    # ------------------------------------------------------------- reset
    def start_tracking(self):
        self._rebuild_layout()
        self.gaze_filter.reset()
        self.tracker.start_tracking()
        self._clear_all_highlights()
        self._set_hud_text("state", "tracking")

    def on_reset_clicked(self):
        if not self.tracker.state.calibrated:
            self.welcome_overlay.show()
            return
        self.start_tracking()
        self.canvas.yview_moveto(0)
        self._set_hud_text("state", "tracking (reset)")

    # ------------------------------------------------------ forced move
    def _on_double_click(self, event):
        if not self.tracker.state.tracking:
            return
        item = self.canvas.find_closest(self.canvas.canvasx(event.x), self.canvas.canvasy(event.y))
        if not item:
            return
        word_id = self._word_id_for_item(item[0])
        if word_id is None:
            return
        now_ms = time.perf_counter() * 1000
        self.tracker.force_relocate(word_id, now_ms)
        self._apply_highlights(force=True)
        self._flash_relocation(word_id)
        self._set_hud_text("state", "tracking (forced relocation)")

    def _word_id_for_item(self, item):
        for w in self.layout.words:
            if w.item_id == item or w.rect_id == item:
                return w.id
        return None

    # -------------------------------------------------------- settings
    def open_settings(self):
        self.settings_overlay.show()

    def _on_camera_select(self, idx):
        self.on_camera_change(idx)

    # ---------------------------------------------------------- gaze loop
    def _poll_gaze(self):
        if not self._gaze_error_shown and getattr(self.gaze_source, "last_error", None):
            self._gaze_error_shown = True
            self._set_hud_text("state", "camera/model error")
            tk.messagebox.showerror("Gaze source error", self.gaze_source.last_error)

        drained = []
        q = self.gaze_source.samples
        while True:
            try:
                drained.append(q.get_nowait())
            except Exception:
                break

        for pitch, yaw, now_ms in drained:
            self._last_pitch_yaw = (pitch, yaw)
            if not self.calibrator.is_fitted:
                continue
            vx, vy = self.calibrator.predict(pitch, yaw)
            self._draw_dot("raw", vx, vy)
            self._set_hud_text("raw", f"{vx:.0f}, {vy:.0f}")

            if self._accuracy_active:
                self._accuracy_samples.append((vx, vy))
                continue

            if not self.tracker.state.tracking:
                continue

            t_sec = now_ms / 1000.0
            sx, sy = self.gaze_filter.filter(vx, vy, t_sec)
            self._draw_dot("cal", sx, sy)
            self._set_hud_text("cal", f"{sx:.0f}, {sy:.0f}")

            cal_x = self.canvas.canvasx(int(sx))
            cal_y = self.canvas.canvasy(int(sy))
            zcut = self.tracker.process_gaze(cal_x, cal_y, now_ms)
            self._apply_highlights()
            self._update_hud(zcut)

        self.root.after(POLL_MS, self._poll_gaze)

    def _update_hud(self, zcut):
        st = self.tracker.state
        self._set_hud_text("line", st.current_line)
        if st.current_word_id is not None and 0 <= st.current_word_id < len(self.layout.words):
            w = self.layout.words[st.current_word_id]
            self._set_hud_text("word", f"{w.text} (#{w.id})")
        else:
            self._set_hud_text("word", "-")
        if zcut:
            self.hud.flash_zcut()
            self.root.after(600, self.hud.clear_zcut)
        self._set_hud_text(
            "reach", f"x={st.zcut_diag.norm_x:.2f} max={st.zcut_diag.reach:.2f}"
        )
        self._set_hud_text("zreason", st.zcut_diag.reason)
        self._set_hud_text("adv", st.line_advanced_by)
        self._set_hud_text(
            "huge", f"{st.huge_dbg.dist:.0f} / {st.huge_dbg.thresh:.0f}px (k=4)"
        )

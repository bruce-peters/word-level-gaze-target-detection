"""Welcome / calibration / accuracy / settings overlays.

Ported from the corresponding <div id="...Overlay"> blocks in index.html and
their wiring in app.js section 9-11. Each overlay is a Frame stacked over the
passage canvas (via .place, matching the JS "hidden class toggle" pattern)
instead of the JS approach of separate always-in-DOM divs.
"""

import tkinter as tk

CLICKS_NEEDED = 5
TARGET_XF = (0.1, 0.5, 0.9)
TARGET_YF = (0.12, 0.5, 0.88)


class Overlay(tk.Frame):
    def show(self):
        self.place(relx=0, rely=0, relwidth=1, relheight=1)
        self.tkraise()

    def hide(self):
        self.place_forget()


class WelcomeOverlay(Overlay):
    def __init__(self, parent, on_start):
        super().__init__(parent, bg="#0b0d12")
        box = tk.Frame(self, bg="#151822", padx=32, pady=28)
        box.place(relx=0.5, rely=0.5, anchor="center")

        tk.Label(box, text="Read with your eyes", fg="#f3f4f6", bg="#151822",
                  font=("Segoe UI", 20, "bold")).pack(anchor="w")
        tk.Label(
            box, fg="#cbd5e1", bg="#151822", justify="left", wraplength=480,
            font=("Segoe UI", 11),
            text="This tracks which word you are reading using your webcam and "
                 "an L2CS-Net gaze model, and highlights it as you go.",
        ).pack(anchor="w", pady=(6, 14))

        steps = [
            "Allow camera access. Video never leaves this machine.",
            "Click each of the 9 dots 5 times, looking straight at your cursor.",
            "Stare at the center dot for 3 seconds to measure accuracy.",
            "Just read. Tracking starts automatically when that's done.",
        ]
        for i, s in enumerate(steps, 1):
            tk.Label(box, text=f"{i}. {s}", fg="#e5e7eb", bg="#151822",
                      justify="left", wraplength=480, font=("Segoe UI", 10)).pack(anchor="w", pady=2)

        tk.Label(
            box, fg="#fbbf24", bg="#151822", justify="left", wraplength=480,
            font=("Segoe UI", 10),
            text="Sit about 50-70cm from the screen, keep your head still, and "
                 "use even lighting on your face.",
        ).pack(anchor="w", pady=(12, 16))

        tk.Button(box, text="Start calibration", command=on_start,
                   font=("Segoe UI", 11, "bold"), bg="#2563eb", fg="white",
                   activebackground="#1d4ed8", bd=0, padx=16, pady=8).pack(anchor="w")


class CalibrationOverlay(Overlay):
    """9-point click calibration. `on_click(idx, x, y)` fires on every dot
    click with the dot's overlay-local (== canvas-local) coordinates -- the
    caller is responsible for pairing that with the current gaze sample."""

    def __init__(self, parent, on_click, on_done, on_cancel):
        super().__init__(parent, bg="#0b0d12")
        self._on_click = on_click
        self._on_done = on_done
        self.counts = {}
        self.targets = {}

        info = tk.Frame(self, bg="#151822", padx=20, pady=14)
        info.place(relx=0.5, rely=0.06, anchor="n")
        tk.Label(info, text="Calibration", fg="#f3f4f6", bg="#151822",
                  font=("Segoe UI", 14, "bold")).pack(anchor="w")
        tk.Label(info, fg="#cbd5e1", bg="#151822", font=("Segoe UI", 10),
                  text="Click each of the 9 dots while looking directly at your cursor. "
                       "5 clicks per dot.").pack(anchor="w")
        self.progress_var = tk.StringVar(value="0 / 9 points complete")
        tk.Label(info, textvariable=self.progress_var, fg="#93c5fd", bg="#151822",
                  font=("Segoe UI", 10, "bold")).pack(anchor="w", pady=(6, 0))

        btns = tk.Frame(info, bg="#151822")
        btns.pack(anchor="w", pady=(10, 0))
        self.done_btn = tk.Button(btns, text="Finish calibration & measure accuracy",
                                    command=self._done, state="disabled",
                                    bg="#2563eb", fg="white", bd=0, padx=10, pady=6)
        self.done_btn.pack(side="left")
        tk.Button(btns, text="Cancel", command=on_cancel, bg="#374151", fg="white",
                   bd=0, padx=10, pady=6).pack(side="left", padx=(8, 0))

        self.canvas = tk.Canvas(self, highlightthickness=0, bg="#0b0d12")
        self.canvas.place(relx=0, rely=0, relwidth=1, relheight=1)
        self.canvas.bind("<Configure>", lambda e: self._rebuild_targets())

    def show(self):
        super().show()
        self._rebuild_targets()

    def _rebuild_targets(self):
        self.canvas.delete("target")
        self.counts = {}
        self.targets = {}
        w = self.canvas.winfo_width() or self.winfo_width()
        h = self.canvas.winfo_height() or self.winfo_height()
        idx = 0
        for fy in TARGET_YF:
            for fx in TARGET_XF:
                x, y = fx * w, fy * h
                oval = self.canvas.create_oval(x - 10, y - 10, x + 10, y + 10,
                                                 fill="#ef4444", outline="white", width=2,
                                                 tags=("target",))
                self.canvas.tag_bind(oval, "<Button-1>", lambda e, i=idx, xx=x, yy=y: self._click(i, xx, yy))
                self.counts[idx] = 0
                self.targets[idx] = oval
                idx += 1
        self._update_progress()

    def _click(self, idx, x, y):
        self.counts[idx] += 1
        self._on_click(idx, x, y)
        frac = min(1.0, self.counts[idx] / CLICKS_NEEDED)
        color = "#22c55e" if self.counts[idx] >= CLICKS_NEEDED else "#f59e0b"
        self.canvas.itemconfig(self.targets[idx], fill=color)
        self._update_progress()

    def _update_progress(self):
        done = sum(1 for c in self.counts.values() if c >= CLICKS_NEEDED)
        self.progress_var.set(f"{done} / 9 points complete")
        ready = done == 9
        self.done_btn.config(state="normal" if ready else "disabled")
        self._ready = ready

    def _done(self):
        if getattr(self, "_ready", False):
            self._on_done()


class AccuracyOverlay(Overlay):
    def __init__(self, parent, on_done):
        super().__init__(parent, bg="#0b0d12")
        self._on_done = on_done
        box = tk.Frame(self, bg="#151822", padx=24, pady=20)
        box.place(relx=0.5, rely=0.5, anchor="center")
        tk.Label(box, text="Accuracy check", fg="#f3f4f6", bg="#151822",
                  font=("Segoe UI", 14, "bold")).pack(anchor="w")
        tk.Label(box, text="Stare at the center dot for a few seconds without moving your head.",
                  fg="#cbd5e1", bg="#151822", font=("Segoe UI", 10)).pack(anchor="w", pady=(4, 10))

        self.dot_canvas = tk.Canvas(box, width=24, height=24, bg="#151822", highlightthickness=0)
        self.dot_canvas.pack()
        self.dot_canvas.create_oval(4, 4, 20, 20, fill="#22c55e", outline="")

        self.result_var = tk.StringVar(value="measuring...")
        tk.Label(box, textvariable=self.result_var, fg="#e5e7eb", bg="#151822",
                  font=("Segoe UI", 10), wraplength=380, justify="left").pack(anchor="w", pady=(10, 10))

        self.done_btn = tk.Button(box, text="Start reading", command=self._done, state="disabled",
                                    bg="#2563eb", fg="white", bd=0, padx=10, pady=6)
        self.done_btn.pack(anchor="w")

    def dot_center(self):
        """Overlay-local (x, y) of the accuracy dot, for the accuracy sampler."""
        self.update_idletasks()
        bx = self.dot_canvas.winfo_rootx() - self.winfo_rootx()
        by = self.dot_canvas.winfo_rooty() - self.winfo_rooty()
        return bx + 12, by + 12

    def set_result(self, text, ready):
        self.result_var.set(text)
        self.done_btn.config(state="normal" if ready else "disabled")

    def _done(self):
        self._on_done()


class SettingsOverlay(Overlay):
    def __init__(self, parent, list_cameras, on_select, on_close):
        super().__init__(parent, bg="#0b0d12")
        self._list_cameras = list_cameras
        self._on_select = on_select
        box = tk.Frame(self, bg="#151822", padx=20, pady=16)
        box.place(relx=0.5, rely=0.5, anchor="center")

        head = tk.Frame(box, bg="#151822")
        head.pack(fill="x")
        tk.Label(head, text="Settings", fg="#f3f4f6", bg="#151822",
                  font=("Segoe UI", 13, "bold")).pack(side="left")
        tk.Button(head, text="✕", command=on_close, bd=0, fg="#e5e7eb", bg="#151822").pack(side="right")

        row = tk.Frame(box, bg="#151822")
        row.pack(fill="x", pady=(12, 4))
        tk.Label(row, text="Video input source", fg="#cbd5e1", bg="#151822",
                  font=("Segoe UI", 10)).pack(side="left")
        self.camera_var = tk.StringVar(value="Camera 0")
        self.camera_menu = tk.OptionMenu(row, self.camera_var, "Camera 0", command=self._select)
        self.camera_menu.pack(side="left", padx=8)
        tk.Button(row, text="Refresh", command=self.refresh, bg="#374151", fg="white",
                   bd=0, padx=8, pady=4).pack(side="left")

        self.hint_var = tk.StringVar(
            value="Switching the camera invalidates calibration -- recalibrate afterwards."
        )
        tk.Label(box, textvariable=self.hint_var, fg="#9ca3af", bg="#151822",
                  font=("Segoe UI", 9), wraplength=360, justify="left").pack(anchor="w", pady=(8, 0))

    def refresh(self):
        cams = self._list_cameras()
        menu = self.camera_menu["menu"]
        menu.delete(0, "end")
        if not cams:
            self.hint_var.set("No cameras found. Connect a webcam and click Refresh.")
            return
        for idx in cams:
            label = f"Camera {idx}"
            menu.add_command(label=label, command=lambda i=idx: self._select_index(i))
        self.camera_var.set(f"Camera {cams[0]}")

    def _select_index(self, idx):
        self.camera_var.set(f"Camera {idx}")
        self._on_select(idx)

    def _select(self, _label):
        pass  # selection handled via _select_index (OptionMenu command kept for label sync)

    def show(self):
        super().show()
        self.refresh()

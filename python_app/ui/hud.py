"""Debug HUD panel. Same fields as the JS HUD table (app.js section 3 / the
#hud markup in index.html)."""

import tkinter as tk


class Hud:
    ROWS = [
        ("state", "state"),
        ("line", "current line"),
        ("word", "current word"),
        ("raw", "raw gaze"),
        ("cal", "calibrated"),
        ("zcut", "Z-cut fired"),
        ("reach", "horiz reach"),
        ("zreason", "Z-cut status"),
        ("huge", "huge-jump dist"),
        ("adv", "last advance"),
    ]

    def __init__(self, parent, on_close=None):
        self.frame = tk.Frame(parent, bg="#111318", bd=1, relief="solid")
        head = tk.Frame(self.frame, bg="#111318")
        head.pack(fill="x", padx=6, pady=(6, 2))
        tk.Label(head, text="Debug HUD", fg="#e5e7eb", bg="#111318",
                  font=("Segoe UI", 10, "bold")).pack(side="left")
        if on_close:
            tk.Button(head, text="✕", command=on_close, bd=0,
                       fg="#e5e7eb", bg="#111318", activebackground="#222").pack(side="right")

        table = tk.Frame(self.frame, bg="#111318")
        table.pack(fill="both", padx=6, pady=(0, 6))

        self.vars = {}
        for r, (key, label) in enumerate(self.ROWS):
            tk.Label(table, text=label, fg="#9ca3af", bg="#111318",
                      font=("Consolas", 9), anchor="w").grid(row=r, column=0, sticky="w", padx=(0, 10))
            var = tk.StringVar(value="-")
            tk.Label(table, textvariable=var, fg="#e5e7eb", bg="#111318",
                      font=("Consolas", 9), anchor="w").grid(row=r, column=1, sticky="w")
            self.vars[key] = var

    def set(self, key, value):
        if key in self.vars:
            self.vars[key].set(str(value))

    def flash_zcut(self):
        self.vars["zcut"].set("YES ↩")

    def clear_zcut(self):
        self.vars["zcut"].set("-")

    def place(self, **kwargs):
        self.frame.place(**kwargs)

    def hide(self):
        self.frame.place_forget()

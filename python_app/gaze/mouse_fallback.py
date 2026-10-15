"""Mouse-driven gaze source, for exercising the app without a webcam or a
working L2CS-Net install.

Same start()/stop()/samples interface as L2CSGazeSource so main.py can swap
sources transparently via --mouse-debug. Global cursor position (via ctypes,
not Tkinter -- safe to poll off the main thread) stands in for pitch/yaw.
Since the Calibrator fits an affine map, feeding raw screen coordinates as
"pitch/yaw" during both calibration clicks and live tracking works out to
~identity mapping automatically -- no special-casing needed anywhere else in
the pipeline.

The ctypes cursor read is Windows-only (`ctypes.windll`). On macOS/Linux the
cursor is read with Tk's `winfo_pointerxy()` instead, which has to run on the
Tk main thread, so there it is polled with `root.after` rather than a
background thread. Pass the Tk root as `root=` for that path.
"""

import ctypes
import queue
import sys
import threading
import time


class _POINT(ctypes.Structure):
    _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]


def _get_cursor_pos():
    pt = _POINT()
    ctypes.windll.user32.GetCursorPos(ctypes.byref(pt))
    return float(pt.x), float(pt.y)


class MouseGazeSource:
    def __init__(self, poll_hz=60, root=None):
        self.poll_interval = 1.0 / poll_hz
        self.root = root  # Tk root, used to read the cursor on non-Windows
        self.samples: "queue.Queue[tuple[float, float, float]]" = queue.Queue(maxsize=4)
        self._thread = None
        self._after_id = None
        self._stop_event = threading.Event()
        self.last_error = None

    def start(self):
        if sys.platform != "win32":
            if self.root is None:
                self.last_error = "--mouse-debug needs the Tk root on non-Windows platforms"
            elif self._after_id is None:
                self._poll_tk()
            return
        if self._thread is not None:
            return
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        if self._after_id is not None:
            try:
                self.root.after_cancel(self._after_id)
            except Exception:
                pass
            self._after_id = None
        self._stop_event.set()
        if self._thread is not None:
            self._thread.join(timeout=2)
        self._thread = None

    def get_preview_frame(self):
        return None  # no camera in mouse-debug mode

    def _push(self, x, y):
        now_ms = time.perf_counter() * 1000
        try:
            self.samples.put_nowait((x, y, now_ms))
        except queue.Full:
            try:
                self.samples.get_nowait()
            except queue.Empty:
                pass
            self.samples.put_nowait((x, y, now_ms))

    def _poll_tk(self):
        try:
            x, y = self.root.winfo_pointerxy()
            self._push(float(x), float(y))
        except Exception as e:
            self.last_error = str(e)
            self._after_id = None
            return
        self._after_id = self.root.after(int(self.poll_interval * 1000), self._poll_tk)

    def _run(self):
        try:
            while not self._stop_event.is_set():
                x, y = _get_cursor_pos()
                self._push(x, y)
                time.sleep(self.poll_interval)
        except Exception as e:
            self.last_error = str(e)

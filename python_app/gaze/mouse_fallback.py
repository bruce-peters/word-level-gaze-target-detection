"""Mouse-driven gaze source, for exercising the app without a webcam or a
working L2CS-Net install.

Same start()/stop()/samples interface as L2CSGazeSource so main.py can swap
sources transparently via --mouse-debug. Global cursor position (via ctypes,
not Tkinter -- safe to poll off the main thread) stands in for pitch/yaw.
Since the Calibrator fits an affine map, feeding raw screen coordinates as
"pitch/yaw" during both calibration clicks and live tracking works out to
~identity mapping automatically -- no special-casing needed anywhere else in
the pipeline.
"""

import ctypes
import queue
import threading
import time


class _POINT(ctypes.Structure):
    _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]


def _get_cursor_pos():
    pt = _POINT()
    ctypes.windll.user32.GetCursorPos(ctypes.byref(pt))
    return float(pt.x), float(pt.y)


class MouseGazeSource:
    def __init__(self, poll_hz=60):
        self.poll_interval = 1.0 / poll_hz
        self.samples: "queue.Queue[tuple[float, float, float]]" = queue.Queue(maxsize=4)
        self._thread = None
        self._stop_event = threading.Event()
        self.last_error = None

    def start(self):
        if self._thread is not None:
            return
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop_event.set()
        if self._thread is not None:
            self._thread.join(timeout=2)
        self._thread = None

    def get_preview_frame(self):
        return None  # no camera in mouse-debug mode

    def _run(self):
        try:
            while not self._stop_event.is_set():
                x, y = _get_cursor_pos()
                now_ms = time.perf_counter() * 1000
                try:
                    self.samples.put_nowait((x, y, now_ms))
                except queue.Full:
                    try:
                        self.samples.get_nowait()
                    except queue.Empty:
                        pass
                    self.samples.put_nowait((x, y, now_ms))
                time.sleep(self.poll_interval)
        except Exception as e:
            self.last_error = str(e)

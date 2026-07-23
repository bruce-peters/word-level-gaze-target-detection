"""Entry point. Wires a gaze source (webcam via uniface/MobileGaze, or
--mouse-debug) into the Tkinter UI (ui/app_window.py).

    python main.py                 # real webcam + gaze model
    python main.py --mouse-debug   # exercise the whole app with the mouse
                                    # standing in for gaze; no camera/model needed
"""

import argparse
import tkinter as tk

from gaze.mouse_fallback import MouseGazeSource
from gaze.uniface_gaze import UniFaceGazeSource
from ui.app_window import AppWindow


def list_cameras(max_index=5):
    try:
        import cv2
    except ImportError:
        return [0]
    found = []
    for i in range(max_index):
        cap = cv2.VideoCapture(i)
        if cap.isOpened():
            found.append(i)
        cap.release()
    return found or [0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mouse-debug", action="store_true",
                         help="Use mouse position instead of a webcam/gaze model.")
    parser.add_argument("--camera", type=int, default=0, help="Camera index to open.")
    args = parser.parse_args()

    root = tk.Tk()
    root.title("Word Gaze Tracker (Python / MobileGaze)")
    root.geometry("1200x800")

    state = {"source": None}

    def make_source(camera_index):
        if args.mouse_debug:
            return MouseGazeSource()
        return UniFaceGazeSource(camera_index=camera_index)

    state["source"] = make_source(args.camera)

    def on_camera_change(idx):
        old = state["source"]
        old.stop()
        new_source = make_source(idx)
        new_source.start()
        state["source"] = new_source
        app.gaze_source = new_source
        app._gaze_error_shown = False

    app = AppWindow(
        root,
        gaze_source=state["source"],
        list_cameras=(lambda: [0]) if args.mouse_debug else list_cameras,
        on_camera_change=on_camera_change,
    )

    def on_close():
        state["source"].stop()
        root.destroy()

    root.protocol("WM_DELETE_WINDOW", on_close)
    root.mainloop()


if __name__ == "__main__":
    main()

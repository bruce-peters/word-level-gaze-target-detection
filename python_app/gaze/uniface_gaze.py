"""Gaze source: webcam -> (pitch, yaw) in radians, on a background thread.

This is new code (WebGazer had no Python equivalent). It runs a
cv2.VideoCapture read loop + face detection + gaze estimation off the Tk main
thread and pushes (pitch, yaw, timestamp_ms) samples into a thread-safe queue
that main.py drains on a `root.after` poll, matching the async-callback shape
of WebGazer's setGazeListener without ever touching Tkinter off the main
thread.

Uses `uniface` (https://github.com/yakhyo/uniface, `pip install uniface[cpu]`)
for both face detection (RetinaFace) and gaze estimation (MobileGaze --
built on top of L2CS-Net, trained on Gaze360, runs on ONNX Runtime). Model
weights are downloaded automatically on first use and SHA-256 verified by
uniface itself -- no manual download step, unlike the original `l2cs`
package this replaced (its weights were only distributed via an
unofficial/unreliable Google Drive folder).
"""

import queue
import threading
import time


class UniFaceGazeSource:
    def __init__(self, camera_index=0):
        self.camera_index = camera_index
        self.samples: "queue.Queue[tuple[float, float, float]]" = queue.Queue(maxsize=4)
        self._thread = None
        self._stop_event = threading.Event()
        self.last_error = None
        self.last_frame = None  # BGR numpy frame, for optional camera preview
        self._frame_lock = threading.Lock()

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
        with self._frame_lock:
            return None if self.last_frame is None else self.last_frame.copy()

    def _run(self):
        try:
            import cv2
            from uniface.detection import RetinaFace
            from uniface.gaze import MobileGaze
        except ImportError as e:
            self.last_error = (
                "Could not import uniface/opencv. Run `pip install -r requirements.txt` "
                f"inside python_app/. ({e})"
            )
            return

        try:
            detector = RetinaFace(confidence_threshold=0.5)
            gaze_estimator = MobileGaze()
        except Exception as e:
            self.last_error = f"Could not load face detector / gaze model: {e}"
            return

        cap = cv2.VideoCapture(self.camera_index)
        if not cap.isOpened():
            self.last_error = f"Could not open camera index {self.camera_index}"
            return

        try:
            while not self._stop_event.is_set():
                ok, frame = cap.read()
                if not ok:
                    continue
                with self._frame_lock:
                    self.last_frame = frame

                try:
                    faces = detector.detect(frame)
                    if not faces:
                        continue
                    x1, y1, x2, y2 = map(int, faces[0].bbox[:4])
                    face_crop = frame[y1:y2, x1:x2]
                    if face_crop.size == 0:
                        continue
                    gaze = gaze_estimator.estimate(face_crop)
                except Exception:
                    continue  # no usable face this frame, skip

                pitch = float(gaze.pitch)
                yaw = float(gaze.yaw)
                now_ms = time.perf_counter() * 1000
                try:
                    self.samples.put_nowait((pitch, yaw, now_ms))
                except queue.Full:
                    try:
                        self.samples.get_nowait()
                    except queue.Empty:
                        pass
                    self.samples.put_nowait((pitch, yaw, now_ms))
        finally:
            cap.release()

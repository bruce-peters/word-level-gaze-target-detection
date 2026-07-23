"""One-Euro filter + pitch/yaw -> screen(x, y) calibration.

The One-Euro filter is a verbatim port of app.js section 8 (the OneEuro
prototype + forward-prediction tunables). The Calibrator is new: WebGazer
produced calibrated screen coordinates internally, but L2CS-Net only gives
head-pose-relative pitch/yaw, so we fit our own linear regression from 9-point
click calibration data, replacing WebGazer's `recordScreenPosition` +
internal ridge regression (app.js section 9) while keeping the same click UX.
"""

import numpy as np


class OneEuro:
    """Adaptive smoothing: hard smoothing when still (kills jitter), opens up
    during fast motion (barely adds lag). One instance per axis."""

    def __init__(self, min_cutoff, beta, dcutoff):
        self.min_cutoff = min_cutoff
        self.beta = beta
        self.dcutoff = dcutoff
        self.x_prev = None
        self.dx_prev = 0.0
        self.t_prev = None

    def _alpha(self, cutoff, dt):
        tau = 1.0 / (2 * np.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)

    def reset(self):
        self.x_prev = None
        self.dx_prev = 0.0
        self.t_prev = None

    def filter(self, x, t):
        """t in seconds. Returns (value, velocity_per_sec)."""
        if self.x_prev is None:
            self.x_prev = x
            self.t_prev = t
            return x, 0.0
        dt = t - self.t_prev
        if not dt > 0:
            dt = 1.0 / 60
        self.t_prev = t
        dx = (x - self.x_prev) / dt
        a_d = self._alpha(self.dcutoff, dt)
        dx_hat = a_d * dx + (1 - a_d) * self.dx_prev
        self.dx_prev = dx_hat
        cutoff = self.min_cutoff + self.beta * abs(dx_hat)
        a = self._alpha(cutoff, dt)
        x_hat = a * x + (1 - a) * self.x_prev
        self.x_prev = x_hat
        return x_hat, dx_hat


# Tunables, unchanged from app.js. beta must stay SMALL for noisy webcam
# gaze: cutoff = min_cutoff + beta*|velocity|, and an inflated velocity
# estimate from noise would blow the cutoff open and turn off smoothing.
FILTER_MIN_CUTOFF = 0.6  # Hz
FILTER_BETA = 0.006
FILTER_DCUTOFF = 0.4  # Hz
LEAD_MS = 25  # forward prediction to compensate pipeline latency
PREDICT_CLAMP_PX = 35  # hard clamp so a noisy velocity spike can't fling the dot


def clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


class GazeFilter:
    """Pairs one OneEuro per axis with the forward-prediction step from
    app.js's onGaze()."""

    def __init__(self):
        self.oe_x = OneEuro(FILTER_MIN_CUTOFF, FILTER_BETA, FILTER_DCUTOFF)
        self.oe_y = OneEuro(FILTER_MIN_CUTOFF, FILTER_BETA, FILTER_DCUTOFF)

    def reset(self):
        self.oe_x.reset()
        self.oe_y.reset()

    def filter(self, x, y, t_sec):
        sx, vx = self.oe_x.filter(x, t_sec)
        sy, vy = self.oe_y.filter(y, t_sec)
        lead = LEAD_MS / 1000.0
        pred_x = clamp(vx * lead, -PREDICT_CLAMP_PX, PREDICT_CLAMP_PX)
        pred_y = clamp(vy * lead, -PREDICT_CLAMP_PX, PREDICT_CLAMP_PX)
        return sx + pred_x, sy + pred_y


class Calibrator:
    """Fits screenX ~= a*pitch + b*yaw + c and screenY ~= d*pitch + e*yaw + f
    from 9-point click samples, replacing WebGazer's internal regression."""

    def __init__(self):
        self.samples = []  # list of (pitch, yaw, screen_x, screen_y)
        self.coef_x = None  # (a, b, c)
        self.coef_y = None  # (d, e, f)

    def add_sample(self, pitch, yaw, screen_x, screen_y):
        self.samples.append((pitch, yaw, screen_x, screen_y))

    def clear(self):
        self.samples = []
        self.coef_x = None
        self.coef_y = None

    @property
    def is_fitted(self):
        return self.coef_x is not None and self.coef_y is not None

    def fit(self):
        if len(self.samples) < 6:
            raise ValueError("Not enough calibration samples to fit a regression")
        data = np.array(self.samples, dtype=float)
        pitch, yaw, sx, sy = data[:, 0], data[:, 1], data[:, 2], data[:, 3]
        A = np.column_stack([pitch, yaw, np.ones_like(pitch)])
        self.coef_x, *_ = np.linalg.lstsq(A, sx, rcond=None)
        self.coef_y, *_ = np.linalg.lstsq(A, sy, rcond=None)

    def predict(self, pitch, yaw):
        if not self.is_fitted:
            return None
        a, b, c = self.coef_x
        d, e, f = self.coef_y
        return a * pitch + b * yaw + c, d * pitch + e * yaw + f

"""Passage renderer + layout model.

Ported from app.js section 1 (renderPassage / buildLayout / buildSentences).
WebGazer's world used DOM <span> elements measured with getBoundingClientRect();
here a Tkinter Canvas plays that role. Words are drawn with create_text and
manually wrapped against the canvas width using font.measure(), producing the
same WORDS / LINES / SENTENCES structures the tracker logic (reading/tracker.py)
consumes.
"""

import re
from dataclasses import dataclass, field

PASSAGE = [
    'A Hare was making fun of the Tortoise one day for being so slow.\n\n'
    '"Do you ever get anywhere?" he asked with a mocking laugh.\n\n'
    '"Yes," replied the Tortoise, "and I get there sooner than you think. '
    "I'll run you a race and prove it.\"\n\n"
    "The Hare was much amused at the idea of running a race with the "
    "Tortoise, but for the fun of the thing he agreed. So the Fox, who had "
    "consented to act as judge, marked the distance and started the runners "
    "off.\n\n"
    "The Hare was soon far out of sight, and to make the Tortoise feel very "
    "deeply how ridiculous it was for him to try a race with a Hare, he lay "
    "down beside the course to take a nap until the Tortoise should catch "
    "up.\n\n"
    "The Tortoise meanwhile kept going slowly but steadily, and, after a "
    "time, passed the place where the Hare was sleeping. But the Hare slept "
    "on very peacefully; and when at last he did wake up, the Tortoise was "
    "near the goal. The Hare now ran his swiftest, but he could not overtake "
    "the Tortoise in time.",
]

ROW_TOL = 12  # px; two words within this vertical distance = same line
PARA_GAP_FACTOR = 0.6  # extra vertical gap between paragraphs, as a fraction of line height
SENTENCE_END_RE = re.compile(r'[.!?]["\')\]]*(?:-+)?$')


@dataclass
class Word:
    id: int
    text: str
    item_id: int
    rect_id: int
    line_index: int = -1
    x_start: float = 0.0
    x_end: float = 0.0
    y_center: float = 0.0
    order_index: int = -1
    sentence_index: int = -1


@dataclass
class Line:
    line_index: int
    y_center: float
    x_min: float
    x_max: float
    width: float
    word_ids: list = field(default_factory=list)


@dataclass
class Sentence:
    index: int
    start_word_id: int
    word_ids: list
    x_min: float
    x_max: float
    y_min: float
    y_max: float


class LayoutModel:
    """Owns the canvas word/line/sentence layout, rebuilt on resize or font change."""

    def __init__(self, canvas, font, x_pad=24, y_pad=24):
        self.canvas = canvas
        self.font = font
        self.x_pad = x_pad
        self.y_pad = y_pad
        self.words: list[Word] = []
        self.lines: list[Line] = []
        self.sentences: list[Sentence] = []
        self.read_order: list[int] = []

    def build(self, width):
        """(Re)draw the passage wrapped to `width` and rebuild the layout model.
        Mirrors renderPassage() + buildLayout() + buildSentences()."""
        self.canvas.delete("word")
        self.words = []
        rows = []  # temp: list of {y_center, words: [Word]}

        line_height = self.font.metrics("linespace")
        para_gap = line_height * PARA_GAP_FACTOR
        space_width = self.font.measure(" ")

        wid = 0
        y = self.y_pad + line_height / 2
        x = self.x_pad
        max_x = width - self.x_pad

        def new_row(yc):
            row = {"y_center": yc, "words": []}
            rows.append(row)
            return row

        cur_row = new_row(y)

        for pi, para in enumerate(PASSAGE):
            if pi > 0:
                y += line_height + para_gap
                x = self.x_pad
                cur_row = new_row(y)

            tokens = para.strip().split()
            for token in tokens:
                w = self.font.measure(token)
                if x + w > max_x and x > self.x_pad:
                    x = self.x_pad
                    y += line_height
                    cur_row = new_row(y)

                item_id = self.canvas.create_text(
                    x, y, text=token, font=self.font, anchor="w", tags=("word",)
                )
                bbox = self.canvas.bbox(item_id)
                x_start, y_top, x_end, y_bot = bbox
                rect_id = self.canvas.create_rectangle(
                    x_start - 2, y_top - 1, x_end + 2, y_bot + 1,
                    fill="", outline="", tags=("word", "word-bg"),
                )
                self.canvas.tag_lower(rect_id, item_id)

                word = Word(
                    id=wid,
                    text=token,
                    item_id=item_id,
                    rect_id=rect_id,
                    x_start=x_start,
                    x_end=x_end,
                    y_center=(y_top + y_bot) / 2,
                )
                self.words.append(word)
                cur_row["words"].append(word)

                x = x_end + space_width
                wid += 1

        self._finish_rows(rows)
        self._build_sentences()
        return self

    def _finish_rows(self, rows):
        rows.sort(key=lambda r: r["y_center"])
        self.read_order = []
        self.lines = []
        for i, row in enumerate(rows):
            if not row["words"]:
                continue
            row["words"].sort(key=lambda w: w.x_start)
            x_min = min(w.x_start for w in row["words"])
            x_max = max(w.x_end for w in row["words"])
            y_sum = 0.0
            for w in row["words"]:
                w.line_index = len(self.lines)
                w.order_index = len(self.read_order)
                self.read_order.append(w.id)
                y_sum += w.y_center
            self.lines.append(
                Line(
                    line_index=len(self.lines),
                    y_center=y_sum / len(row["words"]),
                    x_min=x_min,
                    x_max=x_max,
                    width=x_max - x_min,
                    word_ids=[w.id for w in row["words"]],
                )
            )

    def _build_sentences(self):
        self.sentences = []
        cur = None
        for wid in self.read_order:
            w = self.words[wid]
            if cur is None:
                cur = {"index": len(self.sentences), "start_word_id": wid, "word_ids": []}
            cur["word_ids"].append(wid)
            w.sentence_index = cur["index"]
            if SENTENCE_END_RE.search(w.text):
                self.sentences.append(self._finalize_sentence(cur))
                cur = None
        if cur is not None:
            self.sentences.append(self._finalize_sentence(cur))

    def _finalize_sentence(self, s):
        ids = s["word_ids"]
        x_min = min(self.words[i].x_start for i in ids)
        x_max = max(self.words[i].x_end for i in ids)
        y_min = min(self.words[i].y_center for i in ids)
        y_max = max(self.words[i].y_center for i in ids)
        return Sentence(
            index=s["index"],
            start_word_id=s["start_word_id"],
            word_ids=ids,
            x_min=x_min,
            x_max=x_max,
            y_min=y_min,
            y_max=y_max,
        )

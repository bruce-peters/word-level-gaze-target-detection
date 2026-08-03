// Reads reading_sessions directly from Supabase's PostgREST endpoint via
// plain fetch() -- no supabase-js dependency, same minimal-dependency
// approach swift_app/WordGazeAR/Services/SupabaseClient.swift uses on the
// app side. Uses the service_role key (see config.js, gitignored) because
// the table's only RLS policy (supabase/migrations/0001_reading_sessions.sql)
// grants the anon role insert-only access -- reading everyone's sessions
// needs the key that bypasses RLS. Local-only tool: see README.md.

const els = {
  configWarning: document.getElementById("configWarning"),
  loadState: document.getElementById("loadState"),
  errorState: document.getElementById("errorState"),
  table: document.getElementById("sessionsTable"),
  body: document.getElementById("sessionsBody"),
  emptyState: document.getElementById("emptyState"),
  filterInput: document.getElementById("filterInput"),
  refreshBtn: document.getElementById("refreshBtn"),
  exportCsvBtn: document.getElementById("exportCsvBtn"),
  overlay: document.getElementById("detailOverlay"),
  detailTitle: document.getElementById("detailTitle"),
  detailMeta: document.getElementById("detailMeta"),
  heatmapView: document.getElementById("heatmapView"),
  fixationList: document.getElementById("fixationList"),
  closeDetailBtn: document.getElementById("closeDetailBtn"),
  downloadJsonBtn: document.getElementById("downloadJsonBtn"),
  replayToggle: document.getElementById("replayToggle"),
  replayControls: document.getElementById("replayControls"),
  replayPlayPauseBtn: document.getElementById("replayPlayPauseBtn"),
  replayRestartBtn: document.getElementById("replayRestartBtn"),
  replaySpeedSelect: document.getElementById("replaySpeedSelect"),
  replayProgress: document.getElementById("replayProgress"),
};

let allSessions = [];
let visibleSessions = [];
let selectedSession = null;

// passage_id -> full ordered word array, lazily loaded from passages.json
// (same file the iOS app bundles) so the heatmap can show every word in the
// passage, not just the ones that happen to appear in a session's `heatmap`
// column (which only ever contains words that were actually tracked as the
// "current" word at some point -- everything else was just silently
// missing from the DOM before this fix, not merely unhighlighted).
let passageWordsPromise = null;

function loadPassages() {
  if (!passageWordsPromise) {
    passageWordsPromise = fetch("/swift_app/WordGazeAR/passages.json")
      .then((res) => {
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        return res.json();
      })
      .then((passages) => {
        const map = new Map();
        for (const p of passages) {
          const words = p.text.split(/[ \n\t]+/).filter((w) => w.length > 0);
          map.set(p.id, words);
        }
        return map;
      })
      .catch((err) => {
        console.warn("Could not load passages.json (full-passage heatmap will fall back to tracked words only):", err);
        return new Map();
      });
  }
  return passageWordsPromise;
}

function show(el) {
  el.classList.remove("hidden");
}
function hide(el) {
  el.classList.add("hidden");
}

function isConfigured() {
  return (
    typeof window.SUPABASE_URL === "string" &&
    window.SUPABASE_URL.length > 0 &&
    typeof window.SUPABASE_SERVICE_KEY === "string" &&
    window.SUPABASE_SERVICE_KEY.length > 0
  );
}

async function fetchSessions() {
  const url = `${window.SUPABASE_URL}/rest/v1/reading_sessions?select=*&order=created_at.desc`;
  const res = await fetch(url, {
    headers: {
      apikey: window.SUPABASE_SERVICE_KEY,
      Authorization: `Bearer ${window.SUPABASE_SERVICE_KEY}`,
    },
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Supabase returned HTTP ${res.status}: ${body}`);
  }
  return res.json();
}

function fmtDate(iso) {
  return new Date(iso).toLocaleString();
}

function fmtSeconds(s) {
  return `${Number(s).toFixed(1)}s`;
}

function escapeHtml(str) {
  const div = document.createElement("div");
  div.textContent = str ?? "";
  return div.innerHTML;
}

function renderTable(sessions) {
  visibleSessions = sessions;
  els.body.innerHTML = "";
  if (sessions.length === 0) {
    hide(els.table);
    show(els.emptyState);
    return;
  }
  hide(els.emptyState);
  show(els.table);

  for (const s of sessions) {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>${fmtDate(s.created_at)}</td>
      <td>${escapeHtml(s.participant_name)}</td>
      <td>${s.participant_age ?? "—"}</td>
      <td>${escapeHtml(s.reading_proficiency)}</td>
      <td>${escapeHtml(s.passage_title)}</td>
      <td>${escapeHtml(s.passage_difficulty)}</td>
      <td>${fmtSeconds(s.duration_seconds)}</td>
      <td>${s.word_count}</td>
      <td>${Array.isArray(s.heatmap) ? s.heatmap.length : 0}</td>
    `;
    tr.addEventListener("click", () => openDetail(s));
    els.body.appendChild(tr);
  }
}

async function openDetail(session) {
  selectedSession = session;
  stopReplay();
  els.replayToggle.checked = false;
  hide(els.replayControls);

  els.detailTitle.textContent = `${session.participant_name} — ${session.passage_title}`;
  els.detailMeta.innerHTML = `
    <div><strong>Participant</strong> ${escapeHtml(session.participant_name)}, age ${session.participant_age ?? "—"}, ${escapeHtml(session.reading_proficiency)} proficiency</div>
    <div><strong>Passage</strong> ${escapeHtml(session.passage_title)} (${escapeHtml(session.passage_difficulty)}, ${session.word_count} words)</div>
    <div><strong>When</strong> ${fmtDate(session.created_at)}</div>
    <div><strong>Duration</strong> ${fmtSeconds(session.duration_seconds)}</div>
    <div><strong>Device</strong> ${escapeHtml(session.device_model || "—")} · app ${escapeHtml(session.app_version || "—")}</div>
  `;

  show(els.overlay);

  await renderHeatmap(session);
  renderFixations(session.fixations || []);
}

async function renderHeatmap(session) {
  const heatmap = session.heatmap || [];
  els.heatmapView.innerHTML = "";
  if (heatmap.length === 0) {
    els.heatmapView.textContent = "No heatmap data.";
    return;
  }

  const dwellByIndex = new Map(heatmap.map((w) => [w.word_index, w.seconds]));
  const maxSeconds = Math.max(...heatmap.map((w) => w.seconds), 0.001);
  const passages = await loadPassages();
  const fullWords = passages.get(session.passage_id);

  // Bail out if the detail view got closed/switched to a different session
  // while passages.json was still loading.
  if (selectedSession !== session) return;

  els.heatmapView.innerHTML = "";

  const paintWord = (span, index, word) => {
    span.className = "heatmap-word";
    span.textContent = word;
    span.dataset.wordIndex = index;
    const seconds = dwellByIndex.get(index);
    if (seconds !== undefined) {
      const t = seconds / maxSeconds;
      span.style.backgroundColor = `rgba(245, 158, 11, ${(0.12 + 0.78 * t).toFixed(3)})`;
      span.title = `${word} — ${fmtSeconds(seconds)}`;
    } else {
      span.title = word;
    }
    return span;
  };

  if (fullWords && fullWords.length > 0) {
    // The common case: render every word in the passage, in order, so
    // words that were never fixated still show up (just unhighlighted)
    // instead of silently vanishing from the view.
    fullWords.forEach((word, index) => {
      els.heatmapView.appendChild(paintWord(document.createElement("span"), index, word));
    });
  } else {
    // Fallback if passages.json couldn't be loaded or this passage_id
    // isn't in it (e.g. the bank changed since this session was recorded):
    // show only the words that were actually tracked. Same data as before
    // this fix, clearly labeled so it's not mistaken for the full passage.
    const note = document.createElement("div");
    note.className = "heatmap-note";
    note.textContent = "Couldn't load the full passage text (passages.json unavailable or passage_id not found) — showing only tracked words, not the whole passage.";
    els.heatmapView.appendChild(note);
    const sorted = [...heatmap].sort((a, b) => a.word_index - b.word_index);
    for (const w of sorted) {
      els.heatmapView.appendChild(paintWord(document.createElement("span"), w.word_index, w.word));
    }
  }
}

function renderFixations(fixations) {
  els.fixationList.innerHTML = "";
  if (fixations.length === 0) {
    els.fixationList.textContent = "No fixation data.";
    return;
  }
  fixations.forEach((f, i) => {
    const row = document.createElement("div");
    row.className = "fixation-row";
    row.innerHTML = `<span class="fixation-index">${i + 1}.</span><span class="fixation-word">${escapeHtml(f.word)}</span><span class="fixation-seconds">${fmtSeconds(f.seconds)}</span>`;
    els.fixationList.appendChild(row);
  });
}

// Word-level gaze replay: steps through session.fixations (the same
// ordered (word, seconds) data ReplayView.swift animates on-device) and
// highlights each word in the heatmap view for its recorded dwell time,
// scaled by the selected speed. There's no raw continuous gaze dot here --
// that trail is deliberately never uploaded to Supabase (see
// swift_app/WordGazeAR/Models/SessionRecorder.swift), so this is as
// fine-grained as the web viewer can get.
const replayState = {
  timer: null,
  playing: false,
  index: 0,
  fixations: [],
  spansByIndex: null,
};

function stopReplay() {
  if (replayState.timer) clearTimeout(replayState.timer);
  replayState.timer = null;
  replayState.playing = false;
  els.replayPlayPauseBtn.textContent = "Play";
}

function resetReplayHighlights() {
  els.heatmapView.querySelectorAll(".heatmap-word.current, .heatmap-word.visited").forEach((el) => {
    el.classList.remove("current", "visited");
  });
}

function buildSpanIndex() {
  const map = new Map();
  els.heatmapView.querySelectorAll(".heatmap-word").forEach((el) => {
    const idx = Number(el.dataset.wordIndex);
    if (!Number.isNaN(idx)) map.set(idx, el);
  });
  return map;
}

function startReplay(session) {
  stopReplay();
  resetReplayHighlights();
  replayState.fixations = session.fixations || [];
  replayState.spansByIndex = buildSpanIndex();
  replayState.index = 0;
  replayState.playing = true;
  els.replayPlayPauseBtn.textContent = "Pause";
  els.replayProgress.textContent = `0/${replayState.fixations.length}`;
  stepReplay();
}

function stepReplay() {
  if (!replayState.playing) return;
  const { fixations, index, spansByIndex } = replayState;

  if (index >= fixations.length) {
    replayState.playing = false;
    els.replayPlayPauseBtn.textContent = "Replay finished";
    return;
  }

  if (index > 0) {
    const prev = spansByIndex.get(fixations[index - 1].word_index);
    if (prev) {
      prev.classList.remove("current");
      prev.classList.add("visited");
    }
  }
  const fixation = fixations[index];
  const span = spansByIndex.get(fixation.word_index);
  if (span) {
    span.classList.add("current");
    span.scrollIntoView({ behavior: "smooth", block: "center" });
  }
  els.replayProgress.textContent = `${index + 1}/${fixations.length}`;

  const speed = Number(els.replaySpeedSelect.value) || 3;
  const delayMs = Math.max((fixation.seconds / speed) * 1000, 15);
  replayState.index += 1;
  replayState.timer = setTimeout(stepReplay, delayMs);
}

function togglePlayPause() {
  if (!replayState.fixations.length || replayState.index >= replayState.fixations.length) return;
  replayState.playing = !replayState.playing;
  els.replayPlayPauseBtn.textContent = replayState.playing ? "Pause" : "Play";
  if (replayState.playing) stepReplay();
  else if (replayState.timer) {
    clearTimeout(replayState.timer);
    replayState.timer = null;
  }
}

function applyFilter() {
  const q = els.filterInput.value.trim().toLowerCase();
  if (!q) {
    renderTable(allSessions);
    return;
  }
  renderTable(
    allSessions.filter(
      (s) =>
        (s.participant_name || "").toLowerCase().includes(q) ||
        (s.passage_title || "").toLowerCase().includes(q)
    )
  );
}

function sessionsToCsv(sessions) {
  const headers = [
    "created_at",
    "participant_name",
    "participant_age",
    "reading_proficiency",
    "passage_id",
    "passage_title",
    "passage_difficulty",
    "duration_seconds",
    "word_count",
    "fixated_words",
  ];
  const rows = sessions.map((s) => [
    s.created_at,
    s.participant_name,
    s.participant_age,
    s.reading_proficiency,
    s.passage_id,
    s.passage_title,
    s.passage_difficulty,
    s.duration_seconds,
    s.word_count,
    Array.isArray(s.heatmap) ? s.heatmap.length : 0,
  ]);
  const escapeCsv = (v) => {
    const str = String(v ?? "");
    return /[",\n]/.test(str) ? `"${str.replace(/"/g, '""')}"` : str;
  };
  return [headers, ...rows].map((r) => r.map(escapeCsv).join(",")).join("\n");
}

function downloadFile(filename, contents, mime) {
  const blob = new Blob([contents], { type: mime });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

async function load() {
  hide(els.errorState);
  hide(els.table);
  hide(els.emptyState);
  show(els.loadState);
  try {
    allSessions = await fetchSessions();
    applyFilter();
  } catch (err) {
    els.errorState.textContent = err.message || String(err);
    show(els.errorState);
  } finally {
    hide(els.loadState);
  }
}

els.refreshBtn.addEventListener("click", load);
els.filterInput.addEventListener("input", applyFilter);
els.closeDetailBtn.addEventListener("click", () => {
  stopReplay();
  hide(els.overlay);
});
els.overlay.addEventListener("click", (e) => {
  if (e.target === els.overlay) {
    stopReplay();
    hide(els.overlay);
  }
});
els.replayToggle.addEventListener("change", () => {
  if (!selectedSession) return;
  if (els.replayToggle.checked) {
    show(els.replayControls);
    startReplay(selectedSession);
  } else {
    stopReplay();
    resetReplayHighlights();
    hide(els.replayControls);
  }
});
els.replayPlayPauseBtn.addEventListener("click", togglePlayPause);
els.replayRestartBtn.addEventListener("click", () => {
  if (selectedSession) startReplay(selectedSession);
});
els.downloadJsonBtn.addEventListener("click", () => {
  if (!selectedSession) return;
  downloadFile(`${selectedSession.id}.json`, JSON.stringify(selectedSession, null, 2), "application/json");
});
els.exportCsvBtn.addEventListener("click", () => {
  downloadFile("reading_sessions.csv", sessionsToCsv(visibleSessions), "text/csv");
});

if (!isConfigured()) {
  show(els.configWarning);
} else {
  load();
}

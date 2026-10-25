// Flyout for Usagebar's tray icon. Data comes from the Rust side as a
// snapshot: providers with their last reading, the tray's provider, and when
// it refreshed.

const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const providersEl = document.getElementById("providers");
const updatedEl = document.getElementById("updated");
const refreshButton = document.getElementById("refresh");
let snapshot = null;

function mark(file, width, height, color) {
  const span = document.createElement("span");
  span.className = "mark";
  span.style.setProperty("--src", `url(marks/${file})`);
  span.style.width = `${width}px`;
  span.style.height = `${height}px`;
  if (color) span.style.color = color;
  return span;
}

// Each provider's header matches the macOS menu.
function header(provider) {
  const head = [];
  switch (provider) {
    case "claude": {
      head.push(mark("claude.svg", 15, 15, "var(--claude)"));
      const name = document.createElement("span");
      name.className = "name";
      name.textContent = "Claude";
      head.push(name);
      break;
    }
    case "codex":
      head.push(mark("codex-lockup.svg", 54, 16));
      break;
    case "cursor": {
      const marks = document.createElement("span");
      marks.className = "marks";
      marks.append(
        mark("x.svg", 10, 10),
        mark("grok.svg", 12, 12),
        mark("cursor.svg", 11, 12),
        mark("grokbot.svg", 12, 12),
      );
      head.push(marks);
      break;
    }
  }
  return head;
}

function timeUntil(iso) {
  if (!iso) return "--";
  const seconds = (new Date(iso) - Date.now()) / 1000;
  if (seconds <= 0) return "Now";
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (hours >= 24) return `${Math.floor(hours / 24)}d ${hours % 24}h`;
  if (hours > 0) return `${hours}h ${minutes}m`;
  return `${minutes}m`;
}

function updatedText(iso) {
  if (!iso) return "";
  const minutes = Math.floor((Date.now() - new Date(iso)) / 60000);
  return minutes < 1 ? "Updated just now" : `Updated ${minutes}m ago`;
}

function card(state, inTray) {
  const el = document.createElement("button");
  el.className = "card" + (inTray ? " in-tray" : "");
  el.dataset.provider = state.provider;
  el.title = inTray ? `${state.name} is in the tray` : `Show ${state.name} in the tray`;
  el.addEventListener("click", () => invoke("set_tray_provider", { provider: state.provider }));

  const head = document.createElement("div");
  head.className = "card-head";
  head.append(...header(state.provider));
  const detail = document.createElement("span");
  detail.className = "detail";
  detail.textContent = state.usage?.detail ?? "";
  const pin = document.createElement("span");
  pin.className = "pin";
  head.append(detail, pin);
  el.append(head);

  for (const window of state.usage?.windows ?? []) {
    const row = document.createElement("div");
    row.className = "row";
    const label = document.createElement("span");
    label.className = "label";
    label.textContent = window.label;
    const meter = document.createElement("span");
    meter.className = "meter";
    const fill = document.createElement("span");
    fill.style.width = `${window.used_percent}%`;
    meter.append(fill);
    const percent = document.createElement("span");
    percent.className = "percent";
    percent.textContent = `${window.used_percent}%`;
    const reset = document.createElement("span");
    reset.className = "reset";
    reset.textContent = timeUntil(window.resets_at);
    row.append(label, meter, percent, reset);
    el.append(row);
  }

  if (state.error) {
    const error = document.createElement("div");
    error.className = "error";
    error.textContent = state.usage ? `${state.error}. Showing the last reading.` : state.error;
    el.append(error);
  }
  return el;
}

function render(next) {
  if (next) snapshot = next;
  if (!snapshot) return;
  providersEl.replaceChildren();
  if (snapshot.providers.length === 0) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.innerHTML = "<strong>No providers signed in</strong>Sign in to Claude Code, Codex, or Cursor on this computer and Usagebar picks it up.";
    providersEl.append(empty);
  } else {
    for (const state of snapshot.providers) {
      providersEl.append(card(state, state.provider === snapshot.tray_provider));
    }
  }
  updatedEl.textContent = updatedText(snapshot.updated_at);
  requestAnimationFrame(() => {
    invoke("fit_flyout", { height: document.getElementById("panel").offsetHeight });
  });
}

refreshButton.addEventListener("click", async () => {
  refreshButton.classList.add("spinning");
  try {
    render(await invoke("refresh_now"));
  } finally {
    refreshButton.classList.remove("spinning");
  }
});
document.getElementById("quit").addEventListener("click", () => invoke("quit"));
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") window.__TAURI__.window.getCurrentWindow().hide();
});

listen("snapshot", (event) => render(event.payload));
invoke("get_snapshot").then(render);
// Keep countdowns and "Updated" current while the flyout is open.
setInterval(() => render(), 30000);

const API = window.CLOUDOPS_CONFIG?.apiBaseUrl?.replace(/\/$/, "") || "http://localhost:7071/api";

const listEl = document.getElementById("incident-list");
const form = document.getElementById("incident-form");
const formMessage = document.getElementById("form-message");
const refreshBtn = document.getElementById("refresh-btn");

async function apiFetch(path, options = {}) {
  const headers = { ...(options.headers || {}) };

  if (options.body) {
    headers["Content-Type"] = "application/json";
  }

  const response = await fetch(`${API}${path}`, {
    ...options,
    headers,
  });

  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(body.error || `HTTP ${response.status}`);
  }
  return body;
}

function setHealth(ok, text, timestamp = "") {
  const dot = document.getElementById("health-dot");
  dot.className = `dot ${ok ? "healthy" : "unhealthy"}`;
  document.getElementById("health-text").textContent = text;
  document.getElementById("health-time").textContent = timestamp || "—";
}

async function loadHealth() {
  try {
    const data = await apiFetch("/health");
    setHealth(true, "API healthy", new Date(data.timestamp).toLocaleString());
  } catch (error) {
    setHealth(false, "API unavailable", error.message);
  }
}

function badge(text, className = "") {
  const span = document.createElement("span");
  span.className = `badge ${className}`;
  span.textContent = text;
  return span;
}

function renderIncidents(items) {
  listEl.replaceChildren();

  const stats = {
    open: items.filter(x => x.status === "open").length,
    investigating: items.filter(x => x.status === "investigating").length,
    critical: items.filter(x => x.severity === "critical" && !["resolved", "closed"].includes(x.status)).length,
    resolved: items.filter(x => ["resolved", "closed"].includes(x.status)).length,
  };
  Object.entries(stats).forEach(([key, value]) => {
    document.getElementById(`stat-${key}`).textContent = value;
  });

  if (!items.length) {
    const p = document.createElement("p");
    p.className = "muted";
    p.textContent = "No incidents yet. Create the first one.";
    listEl.appendChild(p);
    return;
  }

  for (const incident of items) {
    const card = document.createElement("article");
    card.className = "incident";

    const top = document.createElement("div");
    top.className = "incident-top";

    const info = document.createElement("div");
    const id = document.createElement("small");
    id.className = "muted";
    id.textContent = incident.id;
    const title = document.createElement("h3");
    title.textContent = incident.title;
    const service = document.createElement("p");
    service.textContent = incident.service;
    info.append(id, title, service);

    const severity = badge(incident.severity, incident.severity);
    top.append(info, severity);

    const description = document.createElement("p");
    description.style.marginTop = "10px";
    description.textContent = incident.description || "No description.";

    const meta = document.createElement("div");
    meta.className = "incident-meta";
    meta.append(badge(incident.status, incident.status));
    if (incident.createdAt) meta.append(badge(new Date(incident.createdAt).toLocaleString()));

    const actions = document.createElement("div");
    actions.className = "incident-actions";

    if (incident.status === "open") {
      const investigate = document.createElement("button");
      investigate.type = "button";
      investigate.className = "secondary small";
      investigate.textContent = "Investigate";
      investigate.addEventListener("click", () =>
        updateStatus(incident.id, "investigating", investigate)
      );
      actions.append(investigate);
    }

    if (!["resolved", "closed"].includes(incident.status)) {
      const resolve = document.createElement("button");
      resolve.type = "button";
      resolve.className = "secondary small";
      resolve.textContent = "Resolve";
      resolve.addEventListener("click", () =>
        updateStatus(incident.id, "resolved", resolve)
      );
      actions.append(resolve);
    }

    card.append(top, description, meta, actions);
    listEl.appendChild(card);
  }
}

async function loadIncidents() {
  listEl.innerHTML = '<p class="muted">Loading incidents...</p>';
  try {
    const data = await apiFetch("/incidents");
    renderIncidents(data.items || []);
  } catch (error) {
    listEl.innerHTML = "";
    const p = document.createElement("p");
    p.className = "muted";
    p.textContent = `Could not load incidents: ${error.message}`;
    listEl.appendChild(p);
  }
}

async function updateStatus(id, status, button = null) {
  const originalText = button?.textContent;

  if (button) {
    button.disabled = true;
    button.textContent =
      status === "investigating" ? "Updating..." : "Resolving...";
  }

  try {
    await apiFetch(`/incidents/${encodeURIComponent(id)}`, {
      method: "PUT",
      body: JSON.stringify({ status }),
    });

    await loadIncidents();
  } catch (error) {
    if (button) {
      button.disabled = false;
      button.textContent = originalText;
    }

    alert(`Update failed: ${error.message}`);
  }
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  formMessage.textContent = "Creating incident...";
  const data = Object.fromEntries(new FormData(form).entries());

  try {
    await apiFetch("/incidents", { method: "POST", body: JSON.stringify(data) });
    form.reset();
    formMessage.textContent = "Incident created.";
    await loadIncidents();
  } catch (error) {
    formMessage.textContent = `Error: ${error.message}`;
  }
});

refreshBtn.addEventListener("click", async () => {
  await Promise.all([loadHealth(), loadIncidents()]);
});

Promise.all([loadHealth(), loadIncidents()]);

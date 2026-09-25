/* Stock Watchlist & Alert System: browser UI.
 *
 * Every piece of data here comes from the FastAPI endpoints (see
 * docs/FRONTEND.md). This file has NO business rules. It does not detect
 * duplicates, compute alerts, or check cooldowns. PostgreSQL does all of
 * that, and this code only displays the results or the error messages.
 * Uses api(), h(), and the format helpers from api.js.
 */
"use strict";

const ALERT_LIMIT = 50;
const HISTORY_LIMITS = [50, 100];

const state = {
  users: [],
  userId: null,
  instruments: null,       // [] once loaded
  watchlists: null,
  rules: null,
  alerts: null,            // latest ALERT_LIMIT alerts, unfiltered (dashboard)
  alertFilter: "",         // instrument_id for the Alert History view, "" = all
  filteredAlerts: null,
  detailId: null,          // instrument open in the Instruments detail panel
  historyLimit: HISTORY_LIMITS[0],
  lastTick: null,          // last body sent from the Demo form (for "Resend")
};

const $ = (id) => document.getElementById(id);

/* ======================================================================
 * small UI building blocks
 * ====================================================================== */
let flashTimer = null;
function flash(message, kind = "success") {
  const box = $("flash");
  box.replaceChildren(h("span", {}, message),
    h("button", {type: "button", className: "flash-close", "aria-label": "Dismiss message",
                 onclick: () => { box.hidden = true; }}, "×"));
  box.className = "flash flash-" + kind;
  box.hidden = false;
  clearTimeout(flashTimer);
  flashTimer = setTimeout(() => { box.hidden = true; }, kind === "error" ? 10000 : 5000);
}

function loading(container, text = "Loading…") {
  container.replaceChildren(h("p", {className: "state state-loading"}, text));
}

function empty(container, text) {
  container.replaceChildren(h("p", {className: "state state-empty"}, text));
}

function failed(container, err) {
  container.replaceChildren(h("p", {className: "state state-error", role: "alert"},
    "Could not load: " + err.message));
}

function table(headers, rows, className = "") {
  return h("div", {className: "table-wrap"},
    h("table", {className},
      h("thead", {}, h("tr", {}, headers.map((text) => h("th", {scope: "col"}, text)))),
      h("tbody", {}, rows)));
}

function badge(text, kind) {
  return h("span", {className: "badge badge-" + kind}, text);
}

function directionBadge(direction) {
  return badge(direction === "ABOVE" ? "▲ ABOVE" : "▼ BELOW", direction === "ABOVE" ? "above" : "below");
}

function instrumentById(id) {
  return (state.instruments || []).find((i) => i.instrument_id === id) || null;
}

function currency(instrumentId) {
  const inst = instrumentById(instrumentId);
  return inst ? inst.quote_currency : "";
}

function price(value, instrumentId) {
  if (value === null || value === undefined) return "–";
  const cur = currency(instrumentId);
  return formatDecimal(value) + (cur ? " " + cur : "");
}

function currentUserName() {
  const user = state.users.find((u) => u.user_id === state.userId);
  return user ? user.username : "this user";
}

/* Put the instrument list into a <select>, keeping the current choice. */
function fillInstrumentSelect(select, firstOption, {activeOnly = false} = {}) {
  const previous = select.value;
  const options = firstOption ? [h("option", {value: ""}, firstOption)] : [];
  for (const inst of state.instruments || []) {
    if (activeOnly && !inst.is_active) continue;
    options.push(h("option", {value: String(inst.instrument_id)},
      inst.exchange + " · " + inst.symbol + (inst.is_active ? "" : " (inactive)")));
  }
  select.replaceChildren(...options);
  if ([...select.options].some((o) => o.value === previous)) select.value = previous;
}

/* ======================================================================
 * navigation
 * ====================================================================== */
const VIEWS = ["dashboard", "watchlists", "rules", "alerts", "instruments", "demo"];

function showView(name) {
  if (!VIEWS.includes(name)) name = "dashboard";
  $("flash").hidden = true;                    // a message belongs to the view it came from
  for (const view of VIEWS) $("view-" + view).hidden = view !== name;
  for (const link of document.querySelectorAll(".nav-link")) {
    if (link.dataset.view === name) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  }
  if (location.hash !== "#" + name) history.replaceState(null, "", "#" + name);
}

/* ======================================================================
 * loading data (each loader handles its own errors, so nothing is left
 * stuck on "Loading…")
 * ====================================================================== */
async function loadHealth() {
  const el = $("health");
  try {
    await api("/health");
    el.textContent = "API + database connected";
    el.className = "health health-ok";
  } catch (err) {
    el.textContent = err.status === 503 ? "Database unavailable" : "Server unreachable";
    el.className = "health health-bad";
  }
}

async function loadUsers() {
  const select = $("user-select");
  try {
    state.users = await api("/users");
  } catch (err) {
    select.replaceChildren(h("option", {}, "Unavailable"));
    flash("Could not load demo users: " + err.message, "error");
    return false;
  }
  if (!state.users.length) {
    select.replaceChildren(h("option", {}, "No users"));
    return false;
  }
  select.replaceChildren(...state.users.map((u) =>
    h("option", {value: String(u.user_id)}, u.username)));
  if (!state.users.some((u) => u.user_id === state.userId)) state.userId = state.users[0].user_id;
  select.value = String(state.userId);
  select.disabled = false;
  return true;
}

async function loadInstruments() {
  loading($("instruments"));
  try {
    state.instruments = await api("/instruments");
  } catch (err) {
    state.instruments = null;
    failed($("instruments"), err);
    renderDashboard();
    return;
  }
  renderInstruments();
  fillInstrumentSelect($("rule-instrument"), null, {activeOnly: true});
  fillInstrumentSelect($("alerts-filter"), "All instruments");
  fillInstrumentSelect($("tick-pick"), "Choose…");
  renderDashboard();
}

async function loadWatchlists() {
  if (state.userId === null) return;
  loading($("watchlists"));
  try {
    state.watchlists = await api(`/users/${state.userId}/watchlists`);
    renderWatchlists();
  } catch (err) {
    state.watchlists = null;
    failed($("watchlists"), err);
  }
  renderDashboard();
}

async function loadRules() {
  if (state.userId === null) return;
  loading($("rules"));
  try {
    state.rules = await api(`/users/${state.userId}/alert-rules`);
    renderRules();
  } catch (err) {
    state.rules = null;
    failed($("rules"), err);
  }
  renderDashboard();
}

async function loadAlerts() {
  if (state.userId === null) return;
  loading($("alerts"));
  try {
    state.alerts = await api(`/users/${state.userId}/alerts?limit=${ALERT_LIMIT}`);
    state.filteredAlerts = state.alertFilter
      ? await api(`/users/${state.userId}/alerts?limit=${ALERT_LIMIT}` +
                  `&instrument_id=${encodeURIComponent(state.alertFilter)}`)
      : state.alerts;
    renderAlerts();
  } catch (err) {
    state.alerts = state.filteredAlerts = null;
    failed($("alerts"), err);
  }
  renderDashboard();
}

const USER_PANELS = ["watchlists", "rules", "alerts", "dashboard-alerts", "dashboard-watchlists"];

function loadUserData() {
  return Promise.all([loadWatchlists(), loadRules(), loadAlerts()]);
}

function showNoUser() {
  for (const id of USER_PANELS) empty($(id), "No demo user available");
}

async function refreshAll() {
  const button = $("refresh-button");
  button.disabled = true;
  button.textContent = "Refreshing…";
  try {
    await loadHealth();
    await loadInstruments();
    if (state.userId === null && !(await loadUsers())) { showNoUser(); return; }
    await Promise.all([loadUserData(), state.detailId ? loadInstrumentDetail(state.detailId) : null]);
  } finally {
    button.disabled = false;
    button.textContent = "Refresh";
  }
}

/* ======================================================================
 * Dashboard: built from data already loaded, so no extra endpoint is needed
 * ====================================================================== */
function renderDashboard() {
  const count = (list, fn = () => true) => (list ? String(list.filter(fn).length) : "–");
  $("stat-watchlists").textContent = count(state.watchlists);
  $("stat-rules").textContent = count(state.rules, (r) => r.is_active);
  $("stat-alerts").textContent = count(state.alerts);
  $("stat-instruments").textContent = count(state.instruments);

  const alertBox = $("dashboard-alerts");
  if (state.alerts === null) loading(alertBox, "–");
  else if (!state.alerts.length) empty(alertBox, "No alerts yet");
  else {
    alertBox.replaceChildren(table(["Fired", "Symbol", "Rule", "Price"],
      state.alerts.slice(0, 5).map((a) => h("tr", {},
        timeCell(a.fired_at),
        h("td", {}, a.symbol),
        h("td", {}, directionBadge(a.direction), " ", formatDecimal(a.threshold)),
        h("td", {className: "num"}, price(a.price, a.instrument_id))))));
  }

  const listBox = $("dashboard-watchlists");
  if (state.watchlists === null) loading(listBox, "–");
  else if (!state.watchlists.length) empty(listBox, "No watchlists yet");
  else {
    listBox.replaceChildren(...state.watchlists.map((wl) => h("div", {className: "overview"},
      h("h4", {}, wl.name, " ", h("span", {className: "muted"},
        "(" + wl.items.length + (wl.items.length === 1 ? " instrument)" : " instruments)"))),
      wl.items.length
        ? h("ul", {className: "chips"}, wl.items.map((it) => h("li", {className: "chip"},
            h("strong", {}, it.symbol), " ",
            it.latest_price === null ? h("span", {className: "muted"}, "no price data yet")
                                     : price(it.latest_price, it.instrument_id))))
        : h("p", {className: "muted"}, "Empty"))));
  }
}

/* ======================================================================
 * Instruments + latest price + history
 * ====================================================================== */
function renderInstruments() {
  const box = $("instruments");
  if (!state.instruments) return;
  const search = $("instrument-search").value.trim().toLowerCase();
  const exchange = $("instrument-exchange").value;
  const rows = state.instruments.filter((i) =>
    (!exchange || i.exchange === exchange) &&
    (!search || i.symbol.toLowerCase().includes(search) || i.name.toLowerCase().includes(search)));
  if (!rows.length) {
    empty(box, state.instruments.length ? "No instruments match this filter" : "No instruments yet");
    return;
  }
  box.replaceChildren(table(["Exchange", "Symbol", "Name", "Currency", "Status", ""],
    rows.map((i) => h("tr", {className: i.instrument_id === state.detailId ? "selected" : ""},
      h("td", {}, i.exchange),
      h("td", {}, h("strong", {}, i.symbol)),
      h("td", {}, i.name),
      h("td", {}, i.quote_currency),
      h("td", {}, i.is_active ? badge("Active", "on") : badge("Inactive", "off")),
      h("td", {className: "actions"}, h("button", {type: "button", className: "button small",
        onclick: () => openInstrumentDetail(i.instrument_id)}, "Latest price & history"))))));
}

function openInstrumentDetail(instrumentId) {
  state.detailId = instrumentId;
  renderInstruments();
  loadInstrumentDetail(instrumentId);
  $("instrument-detail").scrollIntoView({behavior: "smooth", block: "start"});
}

/* Latest tick. 404 "no price ticks yet" is a normal state here, not an error. */
async function fetchLatest(instrumentId) {
  try {
    return await api(`/instruments/${instrumentId}/latest`);
  } catch (err) {
    if (err.status === 404 && /no price ticks/i.test(err.message)) return null;
    throw err;
  }
}

async function loadInstrumentDetail(instrumentId) {
  const box = $("instrument-detail");
  const inst = instrumentById(instrumentId);
  box.hidden = false;
  const heading = h("div", {className: "card-head"},
    h("h3", {}, inst ? inst.exchange + " · " + inst.symbol + " — " + inst.name : "Instrument"),
    h("button", {type: "button", className: "button small", onclick: () => {
      state.detailId = null; box.hidden = true; renderInstruments(); }}, "Close"));
  const body = h("div", {});
  box.replaceChildren(heading, body);
  loading(body);
  let latest, history;
  try {
    [latest, history] = await Promise.all([
      fetchLatest(instrumentId),
      api(`/instruments/${instrumentId}/history?limit=${state.historyLimit}`)]);
  } catch (err) {
    failed(body, err);
    return;
  }
  if (state.detailId !== instrumentId) return;           // user opened another one meanwhile
  if (latest === null) {
    empty(body, "No price data yet");
    body.append(h("p", {className: "muted"},
      "Send a tick from the Demo view or run the offline replay, then press Refresh."));
    return;
  }
  const limitSelect = h("select", {id: "history-limit", onchange: (e) => {
    state.historyLimit = Number(e.target.value); loadInstrumentDetail(instrumentId); }},
    HISTORY_LIMITS.map((n) => h("option", {value: String(n), selected: n === state.historyLimit},
      "Latest " + n)));
  body.replaceChildren(
    h("dl", {className: "latest"},
      h("div", {}, h("dt", {}, "Symbol"), h("dd", {}, inst ? inst.symbol : "#" + instrumentId)),
      h("div", {}, h("dt", {}, "Latest price"), h("dd", {className: "big"}, price(latest.price, instrumentId))),
      h("div", {}, h("dt", {}, "Volume"), h("dd", {}, latest.volume === null ? "unknown" : formatDecimal(latest.volume, 0))),
      h("div", {}, h("dt", {}, "Observed"), h("dd", {title: latest.observed_at}, formatTime(latest.observed_at))),
      h("div", {}, h("dt", {}, "Source"), h("dd", {}, latest.source))),
    h("div", {className: "history-head"},
      h("h4", {}, "Price history (" + history.length + " ticks)"),
      h("div", {className: "field inline"}, h("label", {htmlFor: "history-limit"}, "Show"), limitSelect)),
    priceChart(history),
    table(["Time", "Price", "Volume", "Source"],
      history.slice().reverse().map((t) => h("tr", {},       // newest first in the table
        timeCell(t.observed_at),
        h("td", {className: "num"}, formatDecimal(t.price)),
        h("td", {className: "num"}, t.volume === null ? "–" : formatDecimal(t.volume, 0)),
        h("td", {}, t.source)))));
}

/* A plain SVG line chart, oldest to newest from left to right. Number() is
 * used ONLY to compute pixel positions. Every price shown as text is the
 * exact decimal string from the API. */
function priceChart(ticks) {
  if (ticks.length < 2) return h("p", {className: "muted"}, "The chart needs at least two ticks.");
  const NS = "http://www.w3.org/2000/svg";
  const svg = (tag, attrs, text) => {
    const node = document.createElementNS(NS, tag);
    for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
    if (text !== undefined) node.textContent = text;
    return node;
  };
  const W = 720, H = 220, left = 90, right = 12, top = 14, bottom = 30;
  const values = ticks.map((t) => Number(t.price));
  let min = Math.min(...values), max = Math.max(...values);
  const minText = ticks[values.indexOf(min)].price, maxText = ticks[values.indexOf(max)].price;
  if (min === max) { min -= 1; max += 1; }
  const x = (i) => left + (i * (W - left - right)) / (ticks.length - 1);
  const y = (v) => top + ((max - v) * (H - top - bottom)) / (max - min);

  const chart = svg("svg", {viewBox: `0 0 ${W} ${H}`, class: "chart", role: "img",
    "aria-label": `Price chart of ${ticks.length} ticks, from ${formatDecimal(minText)} to ${formatDecimal(maxText)}`});
  chart.append(
    svg("line", {x1: left, y1: top, x2: left, y2: H - bottom, class: "axis"}),
    svg("line", {x1: left, y1: H - bottom, x2: W - right, y2: H - bottom, class: "axis"}),
    svg("text", {x: left - 8, y: y(Math.max(...values)) + 4, class: "label", "text-anchor": "end"}, formatDecimal(maxText)),
    svg("text", {x: left - 8, y: y(Math.min(...values)) + 4, class: "label", "text-anchor": "end"}, formatDecimal(minText)),
    svg("text", {x: left, y: H - 10, class: "label"}, formatTime(ticks[0].observed_at)),
    svg("text", {x: W - right, y: H - 10, class: "label", "text-anchor": "end"}, formatTime(ticks[ticks.length - 1].observed_at)),
    svg("polyline", {points: values.map((v, i) => `${x(i).toFixed(1)},${y(v).toFixed(1)}`).join(" "), class: "line"}));
  return h("div", {className: "chart-wrap"}, chart);
}

/* ======================================================================
 * Watchlists
 * ====================================================================== */
function renderWatchlists() {
  const box = $("watchlists");
  if (!state.watchlists.length) {
    empty(box, "No watchlists yet. Create one above.");
    return;
  }
  box.replaceChildren(...state.watchlists.map((wl) => {
    const selectId = "add-item-" + wl.watchlist_id;
    const select = h("select", {id: selectId, required: true});
    fillInstrumentSelect(select, "Choose instrument…");
    const items = wl.items.length
      ? table(["Exchange", "Symbol", "Name", "Latest price", "Observed", ""],
          wl.items.map((it) => h("tr", {},
            h("td", {}, it.exchange),
            h("td", {}, h("strong", {}, it.symbol)),
            h("td", {}, it.name),
            h("td", {className: "num"}, it.latest_price === null
              ? h("span", {className: "muted"}, "No price data yet") : price(it.latest_price, it.instrument_id)),
            timeCell(it.latest_observed_at),
            h("td", {className: "actions"}, h("button", {type: "button", className: "button small danger",
              onclick: () => removeItem(wl, it)}, "Remove")))), "items-table")
      : h("p", {className: "state state-empty"}, "No instruments in this watchlist yet");
    return h("article", {className: "card"},
      h("div", {className: "card-head"},
        h("div", {}, h("h3", {}, wl.name),
          h("span", {className: "muted", title: wl.created_at}, "Created " + formatTime(wl.created_at))),
        h("button", {type: "button", className: "button small danger",
          onclick: () => deleteWatchlist(wl)}, "Delete watchlist")),
      items,
      h("form", {className: "form-row compact", onsubmit: (e) => { e.preventDefault(); addItem(wl, select.value); }},
        h("div", {className: "field"}, h("label", {htmlFor: selectId}, "Add instrument"), select),
        h("button", {type: "submit", className: "button"}, "Add")));
  }));
}

async function createWatchlist(event) {
  event.preventDefault();
  const input = $("watchlist-name");
  const name = input.value.trim();
  if (!name) { flash("Enter a watchlist name.", "error"); input.focus(); return; }
  try {
    await api(`/users/${state.userId}/watchlists`, {method: "POST", body: {name}});
  } catch (err) {
    flash(err.constraint === "uq_watchlists_user_name"
      ? `${currentUserName()} already has a watchlist named "${name}".` : err.message, "error");
    return;
  }
  input.value = "";
  flash(`Watchlist "${name}" created.`);
  await loadWatchlists();
}

async function deleteWatchlist(wl) {
  if (!confirm(`Delete the watchlist "${wl.name}"?\n\nIts ${wl.items.length} item(s) are removed ` +
               "from the list. Instruments and price history are kept.")) return;
  try {
    await api(`/watchlists/${wl.watchlist_id}`, {method: "DELETE"});
  } catch (err) {
    flash(err.message, "error");
    await loadWatchlists();
    return;
  }
  flash(`Watchlist "${wl.name}" deleted.`);
  await loadWatchlists();
}

async function addItem(wl, instrumentId) {
  if (!instrumentId) { flash("Choose an instrument to add.", "error"); return; }
  const inst = instrumentById(Number(instrumentId));
  const symbol = inst ? inst.symbol : "That instrument";
  try {
    await api(`/watchlists/${wl.watchlist_id}/items`,
              {method: "POST", body: {instrument_id: Number(instrumentId)}});
  } catch (err) {
    flash(err.constraint === "pk_watchlist_items"
      ? `${symbol} is already in this watchlist.` : err.message, "error");
    return;
  }
  flash(`${symbol} added to "${wl.name}".`);
  await loadWatchlists();
}

async function removeItem(wl, item) {
  if (!confirm(`Remove ${item.symbol} from "${wl.name}"?`)) return;
  try {
    await api(`/watchlists/${wl.watchlist_id}/items/${item.instrument_id}`, {method: "DELETE"});
  } catch (err) {
    flash(err.message, "error");
    await loadWatchlists();
    return;
  }
  flash(`${item.symbol} removed from "${wl.name}".`);
  await loadWatchlists();
}

/* ======================================================================
 * Alert rules: only is_active and cooldown_seconds can change
 * ====================================================================== */
const MAX_COOLDOWN = 2147483647;                         // INTEGER column

function checkCooldown(text) {
  if (!/^\d+$/.test(text.trim())) return "Cooldown must be a whole number of seconds (0 or more).";
  if (Number(text) > MAX_COOLDOWN) return "Cooldown is too large.";
  return null;
}

function renderRules() {
  const box = $("rules");
  if (!state.rules.length) {
    empty(box, "No alert rules yet. Create one above.");
    return;
  }
  box.replaceChildren(table(
    ["#", "Instrument", "Direction", "Threshold", "Cooldown (s)", "Status", "Created", "Actions"],
    state.rules.map((r) => {
      const inputId = "cooldown-" + r.rule_id;
      const cooldown = h("input", {id: inputId, type: "number", min: "0", step: "1",
        value: String(r.cooldown_seconds), className: "cooldown-input"});
      return h("tr", {className: r.is_active ? "" : "row-disabled"},
        h("td", {}, String(r.rule_id)),
        h("td", {}, h("strong", {}, r.symbol), h("span", {className: "muted"}, " " + r.exchange)),
        h("td", {}, directionBadge(r.direction)),
        h("td", {className: "num"}, price(r.threshold, r.instrument_id)),
        h("td", {},
          h("form", {className: "inline-form", noValidate: true, onsubmit: (e) => { e.preventDefault(); saveCooldown(r, cooldown.value); }},
            h("label", {htmlFor: inputId, className: "visually-hidden"}, "Cooldown for rule " + r.rule_id),
            cooldown,
            h("button", {type: "submit", className: "button small"}, "Save"))),
        h("td", {}, r.is_active ? badge("ACTIVE", "on") : badge("DISABLED", "off")),
        timeCell(r.created_at),
        h("td", {className: "actions"},
          h("button", {type: "button", className: "button small", onclick: () => toggleRule(r)},
            r.is_active ? "Disable" : "Enable"),
          h("button", {type: "button", className: "button small danger", onclick: () => deleteRule(r)},
            "Delete")));
    }), "rules-table"));
}

async function createRule(event) {
  event.preventDefault();
  const instrumentId = $("rule-instrument").value;
  const direction = $("rule-direction").value;
  const threshold = $("rule-threshold").value.trim();
  const cooldown = $("rule-cooldown").value.trim();
  const problem = (!instrumentId && "Choose an instrument.") ||
                  checkDecimal(threshold, "Threshold") || checkCooldown(cooldown);
  if (problem) { flash(problem, "error"); return; }
  const inst = instrumentById(Number(instrumentId));
  try {
    // threshold is sent as the text the user typed, so no float rounding happens
    await api(`/users/${state.userId}/alert-rules`, {method: "POST", body: {
      instrument_id: Number(instrumentId), direction, threshold, cooldown_seconds: Number(cooldown)}});
  } catch (err) {
    flash(err.message, "error");
    return;
  }
  $("rule-threshold").value = "";
  flash(`Rule created: ${inst ? inst.symbol : "instrument"} ${direction} ${formatDecimal(threshold)}.`);
  await loadRules();
}

async function patchRule(rule, changes, success) {
  try {
    await api(`/alert-rules/${rule.rule_id}`, {method: "PATCH", body: changes});
  } catch (err) {
    flash(err.message, "error");
    await loadRules();
    return;
  }
  flash(success);
  await loadRules();
}

function toggleRule(rule) {
  return patchRule(rule, {is_active: !rule.is_active},
    `Rule #${rule.rule_id} ${rule.is_active ? "disabled" : "enabled"}.`);
}

function saveCooldown(rule, value) {
  const problem = checkCooldown(value);
  if (problem) { flash(problem, "error"); return; }
  return patchRule(rule, {cooldown_seconds: Number(value)},
    `Rule #${rule.rule_id} cooldown set to ${Number(value)} s.`);
}

async function deleteRule(rule) {
  if (!confirm(`Delete rule #${rule.rule_id} (${rule.symbol} ${rule.direction} ` +
               `${formatDecimal(rule.threshold)})?\n\nDeleting this rule also removes its alert history ` +
               "(alert_events ON DELETE CASCADE).\nTo keep the history, choose Cancel and Disable the rule instead.")) return;
  try {
    await api(`/alert-rules/${rule.rule_id}`, {method: "DELETE"});
  } catch (err) {
    flash(err.message, "error");
    await loadRules();
    return;
  }
  flash(`Rule #${rule.rule_id} and its alert history deleted.`);
  await Promise.all([loadRules(), loadAlerts()]);
}

/* ======================================================================
 * Alert history: shows what PostgreSQL recorded in alert_events
 * ====================================================================== */
function alertRows(alerts) {
  return alerts.map((a) => h("tr", {className: a.direction === "ABOVE" ? "row-above" : "row-below"},
    timeCell(a.fired_at),
    h("td", {}, h("strong", {}, a.symbol), h("span", {className: "muted"}, " " + a.exchange)),
    h("td", {}, directionBadge(a.direction)),
    h("td", {className: "num"}, formatDecimal(a.threshold)),
    h("td", {className: "num"}, h("strong", {}, price(a.price, a.instrument_id))),
    timeCell(a.observed_at),
    h("td", {}, "#" + a.rule_id)));
}

const ALERT_HEADERS = ["Fired", "Instrument", "Direction", "Threshold", "Triggered price", "Observed", "Rule"];

function renderAlerts() {
  const box = $("alerts");
  const list = state.filteredAlerts;
  if (!list.length) {
    empty(box, state.alertFilter ? "No alerts yet for this instrument" : "No alerts yet");
    return;
  }
  box.replaceChildren(table(ALERT_HEADERS, alertRows(list)));
}

/* ======================================================================
 * Demo: manual tick through POST /ticks/ingest, which calls ingest_tick()
 * ====================================================================== */
function newEventId() {
  const random = window.crypto && crypto.randomUUID ? crypto.randomUUID()
    : Date.now().toString(36) + Math.random().toString(36).slice(2);
  return "ui-" + random;
}

async function sendTick(event) {
  event.preventDefault();
  const exchange = $("tick-exchange").value.trim().toUpperCase();
  const symbol = $("tick-symbol").value.trim().toUpperCase();
  const priceText = $("tick-price").value.trim();
  const volumeText = $("tick-volume").value.trim();
  const problem = (!exchange && "Enter an exchange.") || (!symbol && "Enter a symbol.") ||
    checkDecimal(priceText, "Price") ||
    (volumeText && checkDecimal(volumeText, "Volume", {integerDigits: 16, allowZero: true}));
  if (problem) { flash(problem, "error"); return; }
  await ingest({
    exchange, symbol,
    observed_at: new Date().toISOString(),      // timezone-aware (UTC, "Z")
    price: priceText,                           // decimal text, not a float
    volume: volumeText || null,                 // blank = unknown volume (NULL), not zero
    source_event_id: newEventId(),
  });
}

async function ingest(body) {
  const box = $("tick-result");
  box.hidden = false;
  loading(box, "Sending tick…");
  let result;
  try {
    result = await api("/ticks/ingest", {method: "POST", body});
  } catch (err) {
    box.replaceChildren(h("h3", {}, "Tick rejected"),
      h("p", {className: "state state-error", role: "alert"}, err.message));
    return;
  }
  state.lastTick = body;
  $("tick-resend").disabled = false;

  const inst = (state.instruments || []).find((i) => i.exchange === body.exchange && i.symbol === body.symbol);
  const summary = h("dl", {className: "latest"},
    h("div", {}, h("dt", {}, "Result"), h("dd", {},
      badge(result.status, result.status === "INSERTED" ? "on" : "off"))),
    h("div", {}, h("dt", {}, "tick_id"), h("dd", {}, result.tick_id === null ? "– (nothing stored)" : String(result.tick_id))),
    h("div", {}, h("dt", {}, "Instrument"), h("dd", {}, body.exchange + " · " + body.symbol)),
    h("div", {}, h("dt", {}, "Price sent"), h("dd", {}, formatDecimal(body.price))),
    h("div", {}, h("dt", {}, "source_event_id"), h("dd", {className: "mono"}, body.source_event_id)));
  const explain = h("p", {className: "muted"}, result.status === "INSERTED"
    ? "PostgreSQL stored the tick and evaluated the alert rules for this instrument."
    : "PostgreSQL already had a tick with this source_event_id, so nothing was stored " +
      "(UNIQUE (source, instrument_id, source_event_id)).");
  const after = h("div", {});
  box.replaceChildren(h("h3", {}, "Tick " + result.status.toLowerCase()), summary, explain, after);
  flash(`Tick ${result.status}` + (result.tick_id ? ` (tick_id ${result.tick_id})` : "") + ".",
        result.status === "INSERTED" ? "success" : "info");

  // Reload everything that may have changed, then show what PostgreSQL recorded
  await Promise.all([loadUserData(),
    inst && state.detailId === inst.instrument_id ? loadInstrumentDetail(inst.instrument_id) : null]);
  if (!inst) return;
  try {
    const latest = await fetchLatest(inst.instrument_id);
    after.append(h("p", {}, "Latest price of " + inst.symbol + " is now ",
      h("strong", {}, latest ? price(latest.price, inst.instrument_id) : "–"),
      latest ? " (observed " + formatTime(latest.observed_at) + ")." : "."));
  } catch (err) {
    after.append(h("p", {className: "state state-error"}, "Could not load latest price: " + err.message));
  }
  if (result.tick_id !== null && state.alerts) {
    const fired = state.alerts.filter((a) => a.tick_id === result.tick_id);
    after.append(fired.length
      ? h("div", {}, h("h4", {}, `Alerts recorded for ${currentUserName()} by this tick`),
          table(ALERT_HEADERS, alertRows(fired)))
      : h("p", {className: "muted"}, `No alert fired for ${currentUserName()} on this tick. ` +
          "Rules belonging to other users may still have fired."));
  }
}

function pickInstrumentForTick() {
  const inst = instrumentById(Number($("tick-pick").value));
  if (!inst) return;
  $("tick-exchange").value = inst.exchange;
  $("tick-symbol").value = inst.symbol;
  $("tick-price").focus();
}

/* ======================================================================
 * start-up
 * ====================================================================== */
function wireEvents() {
  for (const link of document.querySelectorAll(".nav-link")) {
    link.addEventListener("click", () => showView(link.dataset.view));
  }
  window.addEventListener("hashchange", () => showView(location.hash.slice(1)));
  $("refresh-button").addEventListener("click", refreshAll);
  $("user-select").addEventListener("change", (e) => {
    state.userId = Number(e.target.value);
    state.lastTick = null;
    $("tick-resend").disabled = true;
    $("tick-result").hidden = true;
    loadUserData();
  });
  $("watchlist-form").addEventListener("submit", createWatchlist);
  $("rule-form").addEventListener("submit", createRule);
  $("alerts-filter").addEventListener("change", (e) => { state.alertFilter = e.target.value; loadAlerts(); });
  $("instrument-search").addEventListener("input", renderInstruments);
  $("instrument-exchange").addEventListener("change", renderInstruments);
  $("tick-form").addEventListener("submit", sendTick);
  $("tick-pick").addEventListener("change", pickInstrumentForTick);
  $("tick-resend").addEventListener("click", () => state.lastTick && ingest(state.lastTick));
}

async function start() {
  wireEvents();
  showView(location.hash.slice(1));
  for (const id of USER_PANELS) loading($(id));
  loadHealth();
  await loadInstruments();
  if (await loadUsers()) await loadUserData();
  else showNoUser();
}

start();

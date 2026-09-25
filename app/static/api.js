/* Shared helpers for the web UI:
 *   api()   the one place that calls fetch(). It uses relative URLs, parses
 *           JSON, and turns non-2xx responses into ApiError
 *   h()     builds DOM elements. Text always goes in through textContent,
 *           never innerHTML, so data from the API cannot inject HTML
 *   format helpers for decimals and timestamps
 * The browser talks only to FastAPI. It never connects to PostgreSQL.
 */
"use strict";

class ApiError extends Error {
  constructor(status, message, body) {
    super(message);
    this.status = status;          // HTTP status, or 0 = server unreachable
    this.body = body || {};        // e.g. {detail, sqlstate, constraint}
  }
  get constraint() { return this.body.constraint || null; }
}

/* Turn FastAPI's error body into one readable sentence. */
function errorMessage(status, body) {
  const detail = body && body.detail;
  if (typeof detail === "string") return detail;
  if (Array.isArray(detail) && detail.length) {       // 422 validation errors from Pydantic
    return "Invalid input: " + detail.map((d) => {
      const field = Array.isArray(d.loc) ? d.loc[d.loc.length - 1] : "";
      return (field ? field + ": " : "") + d.msg;
    }).join("; ");
  }
  if (status === 503) return "Database unavailable.";
  return "Request failed (HTTP " + status + ").";
}

/* api("/users"), api("/users/1/watchlists", {method: "POST", body: {...}})
 * Resolves to the parsed JSON (null for 204). Rejects with ApiError. */
async function api(path, options = {}) {
  const init = {method: options.method || "GET", headers: {Accept: "application/json"}};
  if (options.body !== undefined) {
    init.headers["Content-Type"] = "application/json";
    init.body = JSON.stringify(options.body);
  }
  let response;
  try {
    response = await fetch(path, init);               // relative URL: same server as the page
  } catch (err) {
    throw new ApiError(0, "Cannot reach the server. Is uvicorn running?");
  }
  if (response.status === 204) return null;
  let body = null;
  try {
    body = await response.json();
  } catch (err) {
    body = null;                                      // e.g. an HTML error page from a proxy
  }
  if (!response.ok) throw new ApiError(response.status, errorMessage(response.status, body), body);
  return body;
}

/* h("td", {className: "num", title: iso}, "text", childNode, ...) */
function h(tag, props, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props || {})) {
    if (value === undefined || value === null || value === false) continue;
    if (key.startsWith("on")) node.addEventListener(key.slice(2).toLowerCase(), value);
    else if (key === "dataset") Object.assign(node.dataset, value);
    else if (key in node) node[key] = value;
    else node.setAttribute(key, value);
  }
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

/* ---------------------------------------------------------------- *
 * Decimals arrive as exact strings such as "3060.50000000". They are
 * formatted as TEXT (no float conversion), so no digit ever changes.
 * ---------------------------------------------------------------- */
function formatDecimal(value, minFraction = 2) {
  if (value === null || value === undefined) return "–";
  const text = String(value);
  const negative = text.startsWith("-");
  let [whole, fraction = ""] = (negative ? text.slice(1) : text).split(".");
  fraction = fraction.replace(/0+$/, "");
  while (fraction.length < minFraction) fraction += "0";
  whole = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return (negative ? "-" : "") + whole + (fraction ? "." + fraction : "");
}

/* Plain positive decimal text as the user typed it: "3050", "3050.5".
 * integerDigits / fractionDigits mirror the column type, e.g. NUMERIC(18,8)
 * allows 10 integer digits and 8 decimal places. PostgreSQL enforces these
 * too; checking here just gives a quicker, clearer message. */
function checkDecimal(text, label, {integerDigits = 10, fractionDigits = 8, allowZero = false} = {}) {
  const value = text.trim();
  const match = /^(\d+)(?:\.(\d+))?$/.exec(value);
  if (!match) return label + " must be a plain number such as 3050.50.";
  const whole = match[1].replace(/^0+(?=\d)/, "");
  if (whole.length > integerDigits) return label + " is too large (max " + integerDigits + " digits before the point).";
  if ((match[2] || "").length > fractionDigits) return label + " can have at most " + fractionDigits + " decimal places.";
  if (!allowZero && /^[0.]+$/.test(value)) return label + " must be greater than 0.";
  return null;
}

/* ISO timestamp -> readable local time. The raw ISO value goes in a tooltip. */
function formatTime(iso) {
  if (!iso) return "–";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return iso;
  return date.toLocaleString(undefined, {
    year: "numeric", month: "short", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  });
}

function timeCell(iso) {
  return h("td", {className: "time", title: iso || ""}, formatTime(iso));
}

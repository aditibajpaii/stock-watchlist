"""Phase 8 frontend-serving tests - FastAPI TestClient, no Node/npm.

Checks that FastAPI serves the plain HTML/CSS/JS UI, that the API and
/docs still work next to it, and scans the frontend files for things
that must never be there: CDN links, absolute API URLs, database
credentials, innerHTML.

The API checks use one throwaway database built from sql/00, 01, 03, 06.
The dev database stock_watchlist is never touched.

Run (project root, venv active):
    python -m unittest tests.test_frontend -v
"""

import os
import re
import subprocess
import unittest
from html.parser import HTMLParser
from pathlib import Path

import psycopg
from fastapi.testclient import TestClient

from app.main import app

ROOT = Path(__file__).resolve().parent.parent
STATIC = ROOT / "app" / "static"
PG_BIN = Path(os.environ.get("PG_BIN", "/opt/homebrew/opt/postgresql@18/bin"))
TEST_DB = "stock_watchlist_frontend_test"
FRONTEND_FILES = ["index.html", "styles.css", "api.js", "app.js"]

# the 18 Phase 7 API endpoints (method, path)
API_ROUTES = {
    ("GET", "/health"), ("GET", "/users"), ("GET", "/users/{user_id}"),
    ("GET", "/instruments"), ("GET", "/instruments/{instrument_id}"),
    ("GET", "/instruments/{instrument_id}/latest"), ("GET", "/instruments/{instrument_id}/history"),
    ("GET", "/users/{user_id}/watchlists"), ("POST", "/users/{user_id}/watchlists"),
    ("DELETE", "/watchlists/{watchlist_id}"), ("POST", "/watchlists/{watchlist_id}/items"),
    ("DELETE", "/watchlists/{watchlist_id}/items/{instrument_id}"),
    ("GET", "/users/{user_id}/alert-rules"), ("POST", "/users/{user_id}/alert-rules"),
    ("PATCH", "/alert-rules/{rule_id}"), ("DELETE", "/alert-rules/{rule_id}"),
    ("GET", "/users/{user_id}/alerts"), ("POST", "/ticks/ingest"),
}


def admin(sql):
    with psycopg.connect(dbname="postgres", autocommit=True) as conn:
        conn.execute(sql)


def setUpModule():
    admin(f"DROP DATABASE IF EXISTS {TEST_DB}")
    admin(f"CREATE DATABASE {TEST_DB}")
    args = [str(PG_BIN / "psql"), "-X", "-q", "-d", TEST_DB, "-v", "ON_ERROR_STOP=1"]
    for f in ("00_schema.sql", "01_seed.sql", "03_functions_triggers.sql", "06_indexes.sql"):
        args += ["-f", str(ROOT / "sql" / f)]
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr)


def tearDownModule():
    admin(f"DROP DATABASE IF EXISTS {TEST_DB}")


def read(name):
    return (STATIC / name).read_text(encoding="utf-8")


class PageParser(HTMLParser):
    """Collects ids, script src, link href and the visible text of index.html."""

    def __init__(self):
        super().__init__()
        self.ids, self.scripts, self.links, self.labels_for, self.text = set(), [], [], set(), []
        self.buttons = []
        self._in_button = False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if "id" in a:
            self.ids.add(a["id"])
        if tag == "script" and a.get("src"):
            self.scripts.append(a["src"])
        if tag == "link" and a.get("href"):
            self.links.append((a.get("rel"), a["href"]))
        if tag == "label" and a.get("for"):
            self.labels_for.add(a["for"])
        self._in_button = tag == "button"

    def handle_endtag(self, tag):
        if tag == "button":
            self._in_button = False

    def handle_data(self, data):
        self.text.append(data)
        if self._in_button and data.strip():
            self.buttons.append(data.strip())


def parse_index():
    parser = PageParser()
    parser.feed(read("index.html"))
    return parser


class FrontendTests(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.old_db = os.environ.get("DB_NAME")
        os.environ["DB_NAME"] = TEST_DB
        cls.client = TestClient(app)

    @classmethod
    def tearDownClass(cls):
        if cls.old_db is None:
            os.environ.pop("DB_NAME", None)
        else:
            os.environ["DB_NAME"] = cls.old_db

    # 1 --------------------------------------------------------------
    def test_01_root_serves_frontend_html(self):
        r = self.client.get("/")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.headers["content-type"].startswith("text/html"))
        self.assertIn("Real-Time Stock Market Watchlist &amp; Alert System", r.text)
        self.assertEqual(r.text, read("index.html"))
        self.assertEqual(r.headers.get("cache-control"), "no-cache")     # no stale copies after edits

    # 2, 3 -----------------------------------------------------------
    def test_02_css_and_js_are_served(self):
        for path, ctype in (("/static/styles.css", "text/css"), ("/static/app.js", "javascript"),
                            ("/static/api.js", "javascript")):
            with self.subTest(path=path):
                r = self.client.get(path)
                self.assertEqual(r.status_code, 200)
                self.assertIn(ctype, r.headers["content-type"])
                self.assertEqual(r.text, read(path.rsplit("/", 1)[1]))
                self.assertEqual(r.headers.get("cache-control"), "no-cache")

    def test_03_static_serves_only_the_static_folder(self):
        self.assertEqual(self.client.get("/static/missing.js").status_code, 404)
        for path in ("/static/../main.py", "/static/%2e%2e/main.py", "/static/..%2fdb.py"):
            with self.subTest(path=path):
                r = self.client.get(path)
                self.assertNotEqual(r.status_code, 200)
                self.assertNotIn("psycopg", r.text)

    # 4 --------------------------------------------------------------
    def test_04_docs_still_work_and_ui_is_not_in_the_api_schema(self):
        self.assertEqual(self.client.get("/docs").status_code, 200)
        spec = self.client.get("/openapi.json").json()
        self.assertEqual(len(spec["paths"]), 15)            # unchanged since Phase 7
        self.assertNotIn("/", spec["paths"])
        self.assertFalse(any(p.startswith("/static") for p in spec["paths"]))

    # 5 --------------------------------------------------------------
    def test_05_all_18_api_routes_still_registered(self):
        registered = {(m, route.path) for route in app.routes
                      for m in getattr(route, "methods", None) or () if m != "HEAD"}
        self.assertLessEqual(API_ROUTES, registered)
        self.assertEqual(registered - API_ROUTES - {("GET", "/")},
                         {("GET", p) for p in ("/openapi.json", "/docs", "/docs/oauth2-redirect", "/redoc")})

    def test_06_api_still_answers_with_static_serving_enabled(self):
        self.assertEqual(self.client.get("/health").json(), {"status": "ok", "database": "connected"})
        self.assertEqual([u["username"] for u in self.client.get("/users").json()],
                         ["arjun", "priya", "kavya"])
        self.assertEqual(len(self.client.get("/instruments").json()), 7)
        self.assertEqual(self.client.get("/instruments/1/latest").status_code, 404)   # no ticks yet
        self.assertEqual(self.client.get("/users/1/alert-rules").status_code, 200)
        self.assertEqual(self.client.get("/nope").status_code, 404)                  # no catch-all

    # 6 --------------------------------------------------------------
    def test_07_index_references_the_css_and_js(self):
        page = parse_index()
        self.assertEqual(page.scripts, ["/static/api.js", "/static/app.js"])       # api.js first
        self.assertIn(("stylesheet", "/static/styles.css"), page.links)
        for src in page.scripts + [href for rel, href in page.links if rel == "stylesheet"]:
            self.assertTrue((STATIC / src.removeprefix("/static/")).is_file(), src)

    # 7 --------------------------------------------------------------
    def test_08_required_ui_sections_exist(self):
        page = parse_index()
        for view in ("dashboard", "watchlists", "rules", "alerts", "instruments", "demo"):
            self.assertIn("view-" + view, page.ids)
        for element in ("user-select", "refresh-button", "health", "flash",
                        "watchlist-form", "rule-form", "tick-form", "alerts-filter",
                        "instrument-search", "instrument-exchange", "instrument-detail",
                        "stat-watchlists", "stat-rules", "stat-alerts", "stat-instruments"):
            self.assertIn(element, page.ids)
        for nav in ("Dashboard", "Watchlists", "Alert Rules", "Alert History", "Instruments", "Demo"):
            self.assertIn(nav, page.buttons)
        text = " ".join(page.text)
        self.assertIn("Demo user selector, not a login", text)
        self.assertIn("python -m app.replay data/replay_prices.csv --delay-ms 300", text)

    def test_09_every_form_control_has_a_label(self):
        page = parse_index()
        html = read("index.html")
        controls = re.findall(r'<(?:input|select)\b[^>]*\bid="([^"]+)"', html)
        self.assertGreater(len(controls), 10)
        for control in controls:
            self.assertIn(control, page.labels_for, f"no <label for> for #{control}")

    # 8 --------------------------------------------------------------
    def test_10_no_external_resources(self):
        page = parse_index()
        for src in page.scripts + [href for _, href in page.links]:
            self.assertFalse(re.match(r"^(https?:)?//", src), src)
        for name in FRONTEND_FILES:
            text = read(name)
            with self.subTest(file=name):
                # the SVG namespace URI is an identifier, never downloaded
                urls = [u for u in re.findall(r"(?:https?:)?//[\w.-]+\.[a-z]{2,}[^\s\"'`)]*", text)
                        if not u.startswith("http://www.w3.org/2000/svg")]
                self.assertEqual(urls, [])
                self.assertNotRegex(text, r"@import|cdn|googleapis|unpkg|jsdelivr|bootstrap|jquery|react")

    # 9 --------------------------------------------------------------
    def test_11_javascript_uses_relative_api_paths_that_exist(self):
        js = read("api.js") + read("app.js")
        self.assertNotRegex(js, r"localhost|127\.0\.0\.1|:8000")
        code = re.sub(r"/\*.*?\*/|//[^\n]*", "", js, flags=re.S)       # ignore comments
        self.assertEqual(len(re.findall(r"\bfetch\(", code)), 1)      # only inside api()
        calls = re.findall(r"\bapi\(\s*([`\"'])(.*?)\1", code)
        self.assertGreater(len(calls), 10)
        spec_paths = {re.sub(r"\{[^}]+\}", "{}", p) for p in self.client.get("/openapi.json").json()["paths"]}
        for _, path in calls:
            with self.subTest(path=path):
                self.assertTrue(path.startswith("/") and not path.startswith("//"), path)
                normalized = re.sub(r"\$\{[^}]+\}", "{}", path.split("?")[0])
                self.assertIn(normalized, spec_paths)

    # 10 -------------------------------------------------------------
    def test_12_frontend_contains_no_credentials_or_database_access(self):
        for name in FRONTEND_FILES:
            text = read(name).lower()
            with self.subTest(file=name):
                for word in ("password", "passwd", "secret", "token", "postgres://", "postgresql://",
                             "dbname", "db_name", "pgpassword", "psycopg", "5432", "stock_watchlist"):
                    self.assertNotIn(word, text)

    def test_13_no_innerhtml_or_eval_in_javascript(self):
        for name in ("api.js", "app.js"):
            text = read(name)
            with self.subTest(file=name):
                self.assertNotRegex(text, r"\.innerHTML|outerHTML|insertAdjacentHTML|document\.write|\beval\(|new Function")


if __name__ == "__main__":
    unittest.main()

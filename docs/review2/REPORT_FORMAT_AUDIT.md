# Report format audit (no report text written here)

Compares the submitted Review 1 report (`~/Downloads/dbms project.docx.pdf`, 8 pages) with the faculty's
`Project Template - review 2.docx`, section by section. Each row says what exists, what is wrong or
missing, and which ready artifact supports it. **The team writes the report**; this file contains no
prose to paste.

| Template section | In the Review 1 report? | Problems found | Ready support for Review 2 | Status |
|---|---|---|---|---|
| Cover page: title, group members with registration numbers, "Prepared For", "Submitted To Dr. Anand Bihari", school, logo | yes (p.1) | none found | — | OK |
| Abstract | yes (p.2) | three claims need correcting: **"ingest data for hundreds of instruments every second"** (never measured); PostgreSQL justified generically ("highly-relational", "strong support for keys…"); the replay feed is described as a tool for users to "analyze and learn from the market", but it is a deterministic test/demo feed | `VIVA_RECOVERY.md` Q1–Q2 give project-specific reasons | **REWRITE (team)** |
| Table of contents with correct page numbers | yes (p.3) | **page numbers wrong**: Introduction listed as 3 (is 4), Scope 3 (4), Contacts 3 (4), ER Diagram 4 (5), Tables 5 (6–7), Work break down 6 (8), Review evaluation 6 (8). The Review 2 template also has SQL Implementation and Advanced SQL Implementation sections, which are missing. | generate the TOC from headings after adding sections | **FIX** |
| 1 Introduction | yes (p.4) | — | — | OK (team may revise) |
| 2 Project scope | yes (p.4) | lists a "User interface"; the optional Binance live feed is not mentioned; fine as long as it is accurate | — | OK |
| 3 Key contacts and stakeholders | yes (p.4) | column header says "Phone Number/Email" but only phone numbers are given | — | minor |
| 4.1 Software resource requirements | yes (p.4) | no versions. Actual: PostgreSQL 18.6, Python 3.13.15, psycopg 3.3.6, FastAPI 0.141.1, Uvicorn 0.54.0, websockets 17.1 (live feed), httpx 0.28.1 (tests); `requirements.txt` and `psql --version` | versions listed here | **ADD versions** |
| 5 ER diagram ("Updated ER diagram required here") | yes (p.5) but incorrect | arrowheads, no participation, weak-entity misuse, missing keys, naming, typo, contradictions (`DESIGN_CHANGE_LOG.md` D1–D8) | `ER_CORRECTED.png`; optionally `RELATIONAL_SCHEMA.png` labelled as the relational schema | **REPLACE** |
| 6 Tables and constraints ("description of each table, relationships, normal form satisfied by each table, screenshots of the table creation statements") | partly (pp.6–7) | no descriptions, no relationships, no normal forms, no screenshots, column names contradict the ER, most constraints missing | `TABLE_CONSTRAINT_INVENTORY.md`, `SCHEMA_SCREENSHOT_GUIDE.md`, `NORMALIZATION_PROOF.md` | **REBUILD** (screenshots pending) |
| Normal form (marked component in the review table) | **no** | absent | `NORMALIZATION_PROOF.md` | **ADD** |
| 7 SQL implementation (categories A–G, "screenshot of each query with at least one output") | no (not yet required at Review 1) | — | 49 categorized queries (A–G) executed, each with its real output (`QUERY_EVIDENCE.md`); commands in `EVIDENCE_GUIDE.md` | **ADD** (screenshots pending) |
| 8 Advanced SQL implementation (complex queries, views, procedures, functions, triggers, cursors, security) | no | — | CQ01–CQ12, V1–V3, 2 procedures, 3 callable functions, 2 triggers, 2 cursors, 4 roles: all executed, logs in `sql_output/` | **ADD** (screenshots pending) |
| Review 2 checklist items (DML, transactions, index + EXPLAIN) | no | — | `02_dml.out`, `16_transactions.out`, `91_index_explain_benchmark.out` + `INDEX_BENCHMARK.md` | **ADD** |
| Design changes since Review 1 (checklist #10) | no | — | `DESIGN_CHANGE_LOG.md` | **ADD** |
| 10 Work break down | yes (p.8) | "Work Assigned" shows bare numbers (1, 2, 4 / 1, 2, 6 / 1, 2, 5) with no legend. No member is shown as owning normalization. | — (cannot be generated: only the team knows who did what) | **FIX (team)** |
| 11 Review evaluation table | yes (p.8): ER-diagram 3, Table creation with description and screenshot 5, Normal form 2, per member | Review 2 components are set by the faculty; keep the faculty's version | — | keep as given |
| Page header and footer | yes | — | — | OK |

## Placeholders and inconsistencies to search for before submitting

- Any leftover template text ("PROJECT TITLE HERE", "Group Member1 Name", "Team Member 1", "111111111",
  "Malpractice Management System", "Windows XP", "PHP5.5", "Rational Rose"). None appear in the Review 1
  PDF; check again after pasting new template sections.
- Column names in prose must match the database exactly. Search the report for `alert_rule_id`,
  `alert_event_id`, `enabled`, `currency` (as a column), `active` (as a column) and `name` used for
  users: none of these exist in the database.
- Every number quoted in the report needs a source file (`QUERY_EVIDENCE.md`, `sql_output/`,
  `INDEX_BENCHMARK.md`). Do not quote timings from a single EXPLAIN run as a result.
- Each figure needs a caption that says which diagram it is: "Conceptual ER Diagram (Chen notation)"
  or "Relational Schema".

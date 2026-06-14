# agent/ — Python ADK Agent

Hosts a Gemini conversation over A2A and emits A2UI that the Flutter app renders as native widgets.
Reads/writes the Firestore watchlist + price history via function tools and composes the **custom
A2UI catalog** (contract: `shared/catalog/comic_catalog_v1.md`; widgets live in `app/`). All of the
catalog UI is hand-authored in the `agent.py` system prompt (the agent binds data; the widgets own
the look).

## Structure
```
agent/
├─ comic_sales/            # ADK module (folder name = A2A URL segment)
│  ├─ agent.py             # Root agent: callable instruction, A2UI system prompt, registers tools
│  ├─ agent.json           # A2A agent card (required by adk api_server --a2a)
│  ├─ firestore_client.py  # Lazy Firestore singleton (ADC, reads FIRESTORE_PROJECT)
│  └─ tools/
│     ├─ watchlist.py      # get_watchlist, upsert_comic, remove_comic, add_sale
│     └─ price_history.py  # get_price_history(book_id, days, grade?) → summary/by_grade/sales
├─ tools/
│  ├─ seed_watchlist.py    # one-time idempotent Firestore seed/migration
│  └─ backfill_sales.py    # eBay sold-listings scraper → Firestore sales (see "Backfill")
├─ .env                    # GOOGLE_API_KEY, FIRESTORE_PROJECT (gitignored)
└─ pyproject.toml          # uv-managed deps
```

## Run
```bash
cd agent && source .venv/bin/activate
adk api_server --a2a --port 8001 comic_sales   # registers at /a2a/comic_sales
```
NOT `adk web` — it exposes only `/run_sse`; the Flutter GenUI SDK requires the A2A protocol.

## Dependencies (uv, not pip — `uv sync`)
- `google-adk==2.2.0` · `a2ui-agent-sdk` (`A2uiSchemaManager`, `BasicCatalog`) ·
  `a2a-sdk[http-server]==0.3.6` · `google-cloud-firestore`.
- `[backfill]` extra (`curl-cffi`, `beautifulsoup4`, `lxml`) — `uv sync --extra backfill`; kept out
  of the deployed runtime.
> **`[http-server]` is load-bearing.** Plain `a2a-sdk` prunes `starlette`/`sse-starlette` and
> `adk api_server --a2a` fails: "Packages starlette and sse-starlette are required."

## Firestore auth
GCP project **`comic-sales-agent`** (Native mode, `nam5`), **Application Default Credentials** (no
key file): `gcloud auth application-default login`. ADK loads `agent/.env`
(`FIRESTORE_PROJECT=comic-sales-agent`); standalone scripts must pass the var explicitly.

## Tools (each catches all exceptions and returns `{"status":"error",...}`)
A raised exception aborts the A2A turn silently — the app then shows nothing.
- `get_watchlist()` — all `watchlist/{bookId}` docs; derives `last_sale` from the `sales`
  subcollection (prices are NOT stored flat — CPCD §9). Call before showing/answering about the list.
- `upsert_comic(title, issue, book_id?, ...)` — create/edit; **partial update** (only provided
  fields written); empty book_id ⇒ slug from title+issue.
- `remove_comic(book_id)` — deletes the doc + its `sales` subcollection (no cascade).
- `add_sale(book_id, price, ...)` — appends a user-entered sale.
- `get_price_history(book_id, days=90, grade=0)` — summary, per-grade breakdown, chronological
  sales; the basis for the detail view + charts.
- `refresh_sales()` — launches the eBay scraper (`tools/backfill_sales.py --incremental --classify
  --commit`) as a DETACHED `caffeinate -i` background process and returns IMMEDIATELY (a full sweep
  is ~3 hrs, far longer than an A2A turn can block). Wired to the app's "$" Update Sales icon.
  Local-only (residential IP). A PID-file lock (`comic_sales/.refresh/refresh.pid`) blocks a 2nd
  concurrent sweep. See "refresh_sales" below.

## Critical implementation details
- **Callable instruction (DO NOT make it a plain string).** `instruction=instruction` where
  `def instruction(_ctx)->str`. ADK template-substitutes `{…}` tokens in string instructions,
  destroying the embedded A2UI JSON (`KeyError: Context variable not found: expression`).
- **Disable thinking (CRITICAL).**
  `GenerateContentConfig(thinking_config=ThinkingConfig(thinking_budget=0))`. With tools + the large
  A2UI prompt, gemini-2.5-flash thinking returns an EMPTY completion (~25% of turns) → blank render.
- **Model:** `gemini-2.5-flash` only. `gemini-2.0-flash` is decommissioned (404).

## A2UI emission (custom catalog — see `shared/catalog/comic_catalog_v1.md`)
Single surface `comic_surface`, drill-in: every turn re-renders it (REPLACE, no growing stack).
Emit each A2UI message in its OWN `<a2ui-json>` block, **in order**:
1. **createSurface** with `catalogId: "com.comicsales.catalog.v1"` — never skip it (the controller
   buffers updateComponents until it sees createSurface; the app also synthesizes one if it's missing).
2. **updateDataModel** (DETAIL only) — one per bound chart series: the overall trend at `/trend` and
   one per `GradeVarianceRow` grade at `/g_<grade>`. Values are plain numbers, oldest first, copied
   EXACTLY from `get_price_history.sales[]`. Emit BEFORE updateComponents so the bindings resolve.
3. **updateComponents** — the component tree.

- **WATCHLIST** ("show me my watchlist" / a back tap): `get_watchlist()`, then a Column of one
  `WatchlistRow` per comic (bookId/title/subtitle/price). Empty ⇒ a welcome Column prompting the
  user to type their first comic into the input bar.
- **DETAIL** ("show price history and details for book_id X", optionally "… for the last N days" /
  "… for all available history"): pick the window (30/60/90; ALL⇒3650), call
  `get_price_history(book_id=X, days=window)`, then a Column: NavLink back → title Text → MetricCard
  hero (FMV = median) → MetricCluster (Last/Median/Range) → "Price Trend" + WindowToggle + TrendChart
  (`points`={path:/trend}, `days`=window) → GradeTierMatrix → "Grade Variance" (one GradeVarianceRow
  per top grade, demand from its first→last change) → CompsTable (recent sales).
- **Navigation = the action NAME**: `view_book:<book_id>`, `view_book:<id>:<window>`,
  `view_watchlist`. Custom widgets dispatch these; the app maps them back to a text request (see
  `app/CLAUDE.md` "action→text bridge"). Use `NavLink`/custom widgets, NOT BasicCatalog `Button` —
  Button needs its child as a separate component by id, which the model inlines → "Invalid child".
- On a tool `{"status":"error"}`, render ONE Card explaining the failure in plain language.

> **SSE ~9 KB limit RESOLVED.** The app uses non-streaming `message/send`, so the old "keep renders
> to single Text lines" constraint is **lifted** — rich payloads return intact.

## ADK SQLite session store (`comic_sales/.adk/session.db`) — operational gotcha
ADK 2.2.0 stores A2A sessions in SQLite there. **`database is locked`** (concurrent curls + app, or
a SIGKILL mid-request) or **stale-session** errors ⇒ stop the agent,
`rm -f comic_sales/.adk/session.db*` (safe — only A2A conversation state; the watchlist is in
Firestore), start ONE agent, don't hammer it with parallel requests.

## Vendor patch (re-apply after `uv sync`)
`agent/.venv/.../google/adk/cli/fast_api.py` ~L748: inside `if gemini_enterprise_app_name:` change
`import json` → `import json as _json` (the local import shadows the module-level `json` →
`cannot access local variable 'json'`).

## Backfill — eBay sold-listings (`tools/backfill_sales.py`)  ✅ COMPLETE
785 real sales across all 12 books in Firestore (`sales/{saleId}`). Standalone, `--dry-run` default
/ `--commit`. Full design lives in `docs/compact-instructions.md`; the load-bearing facts:
- **Residential IP required** (datacenter/Cloud Run is blocked) → the scraper stays local even after
  Phase 4. `curl_cffi` (Chrome impersonation) + homepage session-warming clears Akamai; it detects
  the Imperva challenge and aborts cleanly. Stay low-rate: `--book-interval 900` (~1 book/15 min).
- Two-stage filter: token heuristic `_matches_book` + optional `--classify` Gemini classifier (fails
  open). Adds a nullable `edition` per sale (additive beyond CPCD §9).
- Routine refresh: `--incremental` (scrapes since newest stored sale − 2d; idempotent ids).
```bash
python tools/backfill_sales.py --classify --book new-mutants-98 --max-pages 1 [--commit]
python tools/backfill_sales.py --classify --incremental --commit          # routine refresh
```
## refresh_sales (`comic_sales/tools/refresh.py`) — app-triggered background refresh  🚧 built, pending on-sim verification
The "$" Update Sales icon dispatches "update my sales" → the agent calls `refresh_sales()`, which
launches `tools/backfill_sales.py --incremental --classify --commit --max-pages 1` as a DETACHED
(`start_new_session=True`) `caffeinate -i`-wrapped subprocess and returns at once. Local-only
(residential IP — see Backfill). Hard-won details:
- **PID-file lock** (`comic_sales/.refresh/refresh.pid`, gitignored under `.refresh/`) → a 2nd tap
  while a sweep runs returns `{"status":"already_running"}` instead of launching a 2nd scraper (two
  scrapers from one IP trip Imperva). Per-run logs at `comic_sales/.refresh/refresh-<ts>.log`.
- **Zombie reaping (CRITICAL).** The detached child is a direct child of the agent process; when it
  exits it lingers as a ZOMBIE that still answers `os.kill(pid, 0)`, so the lock would never release
  within one agent lifetime. `_running_pid()` reaps it first with `os.waitpid(pid, os.WNOHANG)`
  (falls back to the signal probe if it isn't our child, e.g. after an agent restart).
- Pre-flight guards return `{"status":"error"}`: missing scraper file, missing `curl_cffi`
  (`uv sync --extra backfill`), immediate-crash (poll after a 0.3 s grace window).
- System prompt: a tool entry (takes NO args, returns immediately, do NOT re-query after) + a
  **REFRESH view** rendered to `comic_surface` — ← Watchlist NavLink + "Updating Sales" header + the
  tool's `message` verbatim; `started`/`already_running` are informational, `error` is explained.

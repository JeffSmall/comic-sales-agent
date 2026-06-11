# Next session — pick up here

> **How to use:** start a new session and say `read docs/NEXT_SESSION.md`. This file is
> self-bootstrapping — it points you at the rest. Delete or overwrite it once Spike C lands.

We're continuing **Phase 3 / Spike C** of the comic-sales-agent monorepo. First read
`CLAUDE.md`, `agent/CLAUDE.md`, and `docs/CPCD.md` (§8 Phase 3, §9 schema, §11) — they fully
document Spike C. Below is the **live state** those docs can't capture: where we stopped, the
blocker, and the exact next action.

## What was built (all committed/pushed to `main`: 53678bc, a31677e, 2a8c938)

- **`agent/tools/backfill_sales.py`** — an eBay sold-listings scraper that writes ~90 days of
  real sales into each watchlist book's Firestore `sales/{ebay-<itemId>}` subcollection.
  Features:
  - curl_cffi Chrome-TLS impersonation **+ eBay-homepage session-warming** (defeats the Akamai
    TLS block — a plain HTTP client gets a 403).
  - `.s-card` parsing for title / price / sold-date / grade, plus a nullable `edition` field
    (newsstand / direct).
  - Two-stage precision: a cheap contiguous **title+issue** heuristic, then an optional **Gemini
    classifier** (`--classify`) that drops homage/variant/reprint listings the heuristic can't
    catch (validated 15/15 offline).
  - Manual low-rate modes: `--book <id>` (one book), `--book-interval <sec>` (paced sweep).
  - `--incremental` refresh: per book, cutoff = `(newest stored sale_date − 2d)` so irregular
    run intervals leave no gap; idempotent ids make the overlap free.
  - `--dry-run` by default; `--commit` to persist.
- Scrape deps (`curl_cffi`, `beautifulsoup4`, `lxml`) are in the pyproject `[backfill]` extra
  and are **already synced into `agent/.venv`** (no `uv run --with` needed). The script
  auto-loads `agent/.env` (so `FIRESTORE_PROJECT` / `GOOGLE_API_KEY` are picked up).
- Script compiles clean; classifier and the `--incremental` fallback are verified.

## Current state / the blocker

- The watchlist has **12 books**. Firestore `sales` is **EMPTY** — the live backfill has NOT
  run yet, so the **Spike C gate (≥3 books with ~90d of grade-level sales) is NOT met.**
- **BLOCKER:** eBay's Imperva **"Pardon Our Interruption"** rate-limit. We tripped it several
  times last session; it needs a real **cool-down (30–45+ min of zero eBay traffic)**, and
  probing while blocked only extends it. The scrape **only works from a residential IP** (a
  Cloud Run / datacenter IP is blocked).

## Immediate next action

1. **Probe with a single-book LIVE dry-run** (2 requests; aborts cleanly if still blocked):
   ```
   cd agent && source .venv/bin/activate
   python tools/backfill_sales.py --classify --book new-mutants-98 --max-pages 1
   ```
   > Bash runs sandboxed — eBay / Firestore / Gemini calls need network, so run these with the
   > sandbox disabled.
2. **If it returns clean classified sales** → start landing data. Commit per book, spaced out:
   ```
   python tools/backfill_sales.py --classify --book new-mutants-98 --max-pages 1 --commit
   ```
   …or one paced sweep of all 12: `... --book-interval 900 --max-pages 1 --commit`.
   Always dry-run a book before `--commit` and eyeball that the classifier kept genuine keys.
3. **If "Pardon Our Interruption"** → still blocked; wait longer, don't keep probing.

## After the backfill lands (Phase 3 remainder)

- Verify Firestore has real grade-level sales for ≥3 books (clears the Spike C gate); switch
  routine refreshes to `--incremental`.
- Build: `get_price_history(bookId, days, grade?)` ADK tool; the planned **non-blocking
  `refresh_sales` tool + Flutter "Update Sales" button** (detached, `caffeinate`-wrapped,
  local-agent-only); then the visualization catalog items (`Sparkline`, `GradeTierMatrix`,
  `SmallMultiplesGrid`).
- Still outstanding from earlier phases: `docs/tufte-infographics.md` is a stub and
  `shared/catalog/` is empty — both feed the visualization catalog work.

## Conventions

- Commit directly to `main` (solo prototype; no branch/PR flow).
- **Do not touch eBay until the cool-down has genuinely passed.**

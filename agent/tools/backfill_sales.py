"""
Spike C (Phase 3) — one-time historical backfill of eBay sold listings into Firestore.

Scrapes ~90 days of completed/sold eBay listings for every book in the Firestore
watchlist and writes each sale as a `watchlist/{bookId}/sales/{saleId}` document with a
per-sale `grade` (see docs/CPCD.md §8 Spike C and §9 schema). This gives the Phase 3
visualization catalog (Sparkline, GradeTierMatrix, SmallMultiplesGrid) real grade-level
data to render against from day one, instead of the synthetic seed data.

Why a spike (and what was de-risked here):
  - eBay blocks plain HTTP scraping at the TLS-fingerprint layer (Akamai bot manager).
    A normal `requests`/`curl` call gets a 403 error page regardless of headers or IP.
    The working approach: `curl_cffi` impersonating a real Chrome TLS/HTTP2 fingerprint,
    AND "warming" the session by fetching the eBay homepage first so the bot-manager
    cookies (bm_ss/bm_so/__uzm*) are set before the search request. With both, the search
    returns HTTP 200 and real results HTML.
  - eBay's current search layout uses `.s-card` / `.su-card-container` nodes (NOT the old
    `.s-item` classes). Each card yields title, price, sold-date, listing URL.
  - Completed/sold listings only retain ~90 days of history publicly — that is the window
    we capture (no synthesizing older data for this spike).
  - The flagged parsing hazards are real and are filtered here: a "New Listing" title
    prefix, facsimile/reprint/reproduction contamination (a $200 facsimile sits right next
    to the real $18,500 key), multi-book lots, and wrong-issue noise.

Idempotency: each sale's document id is `ebay-<ebayItemId>` (extracted from the /itm/<id>
listing URL), so re-running upserts the same sale rather than duplicating it — same
discipline as tools/seed_watchlist.py.

Precision: the contiguous title+issue heuristic removes wrong-series junk cheaply, but
can't catch homage/variant covers and reprints that print the key's name in their own
title. The optional `--classify` flag runs a Gemini pass over the survivors to drop those
(and refine newsstand/direct edition). It reuses GOOGLE_API_KEY from agent/.env, which the
script now loads itself.

Dependencies (kept out of the deployed agent runtime — see pyproject `[backfill]` extra):
    curl_cffi, beautifulsoup4, lxml   (google-genai for --classify is already an agent dep)

Rate-limit strategy (the prototype's manual, on-demand approach): eBay's Imperva bot-manager
trips on request *velocity*, so we scrape ONE book per run (~2 requests) and space books ~15
min apart. Two ways to drive it:

  Per-book (lowest rate — run it once per book, spaced however you like):
    python tools/backfill_sales.py --classify --book amazing-fantasy-15 --commit

  Paced sweep (one long-running process; sleeps --book-interval between books):
    python tools/backfill_sales.py --classify --book-interval 900 --commit

After the first 90-day backfill, keep data fresh with --incremental: per book it scrapes only
since (newest stored sale - 2d), so running at irregular intervals (skip a day, a week) never
leaves a gap, and deterministic ebay-<itemId> ids make the overlap free (upsert, not dupe).
Books with no prior sales fall back to the full --days window; gaps beyond eBay's ~90-day
retention can't be recovered.
    python tools/backfill_sales.py --classify --incremental --book new-mutants-98 --commit

Dry-run prints what it WOULD write and touches nothing; .env is auto-loaded. Use
--book-interval 0 for a quick multi-book dry-run without the 15-min waits:
    python tools/backfill_sales.py --classify --book-interval 0 --max-pages 1

Or without installing the scrape deps into the venv, prefix with:
    uv run --with curl_cffi --with beautifulsoup4 --with lxml ...
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

# Allow running as a plain script: make the comic_sales package importable.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from google.cloud import firestore  # noqa: E402

from comic_sales.firestore_client import db  # noqa: E402

_WATCHLIST = "watchlist"
_SALES = "sales"

# Incremental mode: re-scrape from a few days before the newest sale we already have, so
# irregular run intervals never leave a gap, and idempotent ids make the overlap free.
_INCREMENTAL_OVERLAP_DAYS = 2
_EBAY_RETENTION_DAYS = 90  # eBay keeps ~90 days of sold listings; older gaps are unrecoverable

_EBAY_HOME = "https://www.ebay.com"
_EBAY_SEARCH = "https://www.ebay.com/sch/i.html"
# A real desktop Chrome fingerprint for curl_cffi to impersonate.
_IMPERSONATE = "chrome124"
_PER_PAGE = 240  # _ipg — max items per results page
_REQUEST_PAUSE_S = 3.0  # be a polite scraper; avoid hammering eBay between pages

# Optional Gemini title classifier (--classify): a precision pass over the heuristic
# survivors, dropping homage/variant/reprint listings that contiguous matching can't catch.
_CLASSIFIER_MODEL = "gemini-2.5-flash"
_CLASSIFIER_BATCH = 40

# Sold-date caption, e.g. "Sold  Jun 10, 2026"
_SOLD_DATE_RE = re.compile(r"Sold\s+([A-Z][a-z]{2}\s+\d{1,2},\s+20\d{2})")
# Grade, e.g. "CGC 9.8", "CBCS9.6", "PGX 7.0", "CGC GRADE 9.8". Requires a grading company +
# a 0.5..10 number; an optional "grade"/"graded" word may sit between (sellers write
# "CGC GRADE 9.8" / "CGC GRADED 9.6"). Decimals run .0/.2/.4/.6/.8 (and .5 at the low end),
# so allow any single decimal digit.
_GRADE_RE = re.compile(
    r"\b(CGC|CBCS|PGX|EGC)\s*(?:graded?\s*)?(10(?:\.0)?|[0-9](?:\.\d)?)\b", re.I
)
# Money, e.g. "$18,500.00"
_PRICE_RE = re.compile(r"\$\s*([0-9][0-9,]*(?:\.\d{2})?)")
# eBay listing id from a /itm/<id> URL.
_ITEM_ID_RE = re.compile(r"/itm/(?:[^/]+/)?(\d{9,15})")

# Newsstand vs. direct edition — detectable ONLY from explicit title wording. Newsstand
# copies (UPC barcode) often command a premium over the direct edition (publisher logo in
# the box), so capturing it sharpens grade-level price analysis. We label only when the
# seller says so; silence -> None (unknown), never an assumed "direct".
_NEWSSTAND_RE = re.compile(r"\bnews\s?stand\b|\bupc\b", re.I)
_DIRECT_RE = re.compile(r"\bdirect\s+(?:edition|market|ed\b)\b", re.I)

# Titles we never want to record as a sale of the real book: reprints, collected editions,
# and merchandise. `facs\w*`/`fasc\w*` catch facsimile and its frequent misspellings
# (facsimile, facsmile, fascimile, facsim).
_REJECT_TITLE_RE = re.compile(
    r"\bfacs\w*|\bfasc\w*|"
    r"\b(reprint|reproduction|replica|milestone|masterworks?|omnibus|"
    r"visionaries|true\s+believers|epic\s+collection|gn-?tpb|"
    r"tpb|trade\s+paperback|hard\s?cover|paperback|reading\s+copy|"
    r"marvel\s+tales|lot\s+of|\blot\b|set\s+of|bundle|read\s+description|"
    r"coverless|poster|magnet|sticker|t-?shirt|custom|sketch\s+cover\s+blank)\b",
    re.I,
)


@dataclass
class Sale:
    item_id: str
    title: str
    price: float
    sale_date: datetime
    grade: float | None
    edition: str | None  # "newsstand" | "direct" | None (unknown)
    url: str

    @property
    def raw_or_graded(self) -> str:
        return "graded" if self.grade is not None else "raw"

    @property
    def sale_id(self) -> str:
        return f"ebay-{self.item_id}"


class EbayBlockedError(RuntimeError):
    """eBay issued a hard anti-bot challenge that a fresh session can't clear from this IP."""


def _looks_blocked(html: str) -> bool:
    """A real results page is ~1MB+. eBay's bot-block/error pages are a few KB and carry
    tell-tale text. After several requests on one session eBay starts serving these even
    though warm-up succeeded — detecting it lets the client re-warm and retry.
    """
    if len(html) < 50_000:
        return True
    low = html.lower()
    return "something went wrong on our end" in low or "pardon our interruption" in low


def _is_hard_challenge(html: str) -> bool:
    """Imperva's "Pardon Our Interruption" interstitial. Once this fires, the IP is flagged
    and only a cool-down (or a different IP / a challenge-solving proxy) clears it — re-warming
    the same IP just digs deeper, so we abort rather than retry.
    """
    return "pardon our interruption" in html.lower()


class EbayClient:
    """A curl_cffi client that warms eBay's bot-manager cookies and transparently
    re-warms (fresh session + backoff) when eBay starts throttling mid-run.
    """

    def __init__(self) -> None:
        self._session = None
        self._warm()

    def warm(self) -> None:
        """Re-prime a fresh warmed session. Call before each book in a spaced sweep so every
        book starts with fresh bot-manager cookies (they go stale across 15-min gaps)."""
        self._warm()

    def _warm(self) -> None:
        from curl_cffi import requests as cffi_requests

        session = cffi_requests.Session()
        home = session.get(_EBAY_HOME, impersonate=_IMPERSONATE, timeout=40)
        if home.status_code != 200:
            raise RuntimeError(
                f"eBay homepage warm-up returned {home.status_code}; cannot prime bot "
                "cookies. eBay may be blocking this network — try again later or from a "
                "different connection."
            )
        self._session = session

    def get_page(self, query: str, page: int) -> str:
        """Return results HTML for one sold-search page, re-warming on a detected block.

        Returns "" if still blocked after retries; the caller then sees zero cards and
        moves on rather than crashing the whole run.
        """
        params = {
            "_nkw": query,
            "LH_Sold": "1",
            "LH_Complete": "1",
            "_ipg": str(_PER_PAGE),
            "_sop": "13",  # sort: ended recently (newest sold first)
            "_pgn": str(page),
        }
        for attempt in range(3):
            resp = self._session.get(
                _EBAY_SEARCH,
                params=params,
                impersonate=_IMPERSONATE,
                timeout=40,
                headers={"Referer": f"{_EBAY_HOME}/"},
            )
            html = resp.text if resp.status_code == 200 else ""
            if html and not _looks_blocked(html):
                return html
            if html and _is_hard_challenge(html):
                raise EbayBlockedError(
                    "eBay served its 'Pardon Our Interruption' anti-bot challenge — this IP "
                    "is rate-limited. Wait ~15–30 min before retrying, and space runs out "
                    "(the spike's eBay data is only refreshed for a one-time backfill)."
                )
            # Soft throttle (small/empty page, no challenge): back off and re-warm.
            time.sleep(4 * (attempt + 1))
            self._warm()
        return ""


def _search_query(title: str, issue: str) -> str:
    """Build an eBay keyword query from a book's title and issue.

    Broad on purpose: we want both raw and graded sales (per-sale grade is parsed from the
    title), so we do NOT force "cgc" into the query. Issue '#15' -> '15'.
    """
    issue_num = issue.lstrip("#").strip()
    return f"{title} {issue_num}".strip()


def _parse_price(text: str) -> float | None:
    # Price ranges ("$10.00 to $25.00") are auction/active artifacts, not a single sold
    # price — skip them.
    if re.search(r"\bto\b", text) and text.count("$") > 1:
        return None
    m = _PRICE_RE.search(text)
    if not m:
        return None
    try:
        return float(m.group(1).replace(",", ""))
    except ValueError:
        return None


def _parse_grade(title: str) -> float | None:
    m = _GRADE_RE.search(title)
    if not m:
        return None
    try:
        g = float(m.group(2))
    except ValueError:
        return None
    return g if 0.5 <= g <= 10.0 else None


def _parse_edition(title: str) -> str | None:
    # Newsstand wins ties: a copy explicitly called newsstand is newsstand even if "direct"
    # also appears (e.g. comparison text). Absence of both -> unknown.
    if _NEWSSTAND_RE.search(title):
        return "newsstand"
    if _DIRECT_RE.search(title):
        return "direct"
    return None


def _parse_sold_date(text: str) -> datetime | None:
    m = _SOLD_DATE_RE.search(text)
    if not m:
        return None
    try:
        d = datetime.strptime(m.group(1), "%b %d, %Y")
        return d.replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def _norm(s: str) -> str:
    """Lowercase, collapse every run of non-alphanumeric chars to a single space, and trim.

    Keeping a space (rather than deleting it) preserves token boundaries, so the issue number
    can be matched as a standalone word. Deleting separators is lossy: "#92 1st" would become
    "921st" and "#1 (1975)" would become "11975", running the issue into trailing digits.
    """
    return re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()


def _matches_book(title: str, issue: str, listing_title: str) -> bool:
    """True only if the listing title contains the book's title followed by its issue number
    as a standalone token, optionally separated by a 4-digit publication year (comic listings
    very often read "X-Men (1975) #94" or "Detective Comics 359 1967").

    A bare issue-number check ("\\b15\\b") is hopeless — "15"/"1" appear in countless unrelated
    titles. Requiring "<title> [year] <issue>" rejects different series ("Immortal Hulk"), most
    reprints whose edition word splits the title from the issue ("Giant-Size X-Men Facsimile
    Edition #1"), and SEO noise. The `\\b` token boundary keeps the issue a whole number, so
    "#94" matches neither "#194" nor "#940".

    Known residuals it still can't catch: homage/variant covers that literally print
    "<title> <issue>", listings where a non-year word ("No.", "Vol 1") separates title from
    issue, and broader-named series that contain the title ("Classic X-Men #1" for "X-Men #1")
    — all left to the reject list / Gemini classifier or accepted as a small recall loss.
    """
    num = issue.lstrip("#").strip()
    t = _norm(title)
    lt = _norm(listing_title)
    if not t:
        return False
    if not num:
        return re.search(rf"\b{re.escape(t)}\b", lt) is not None
    pat = rf"\b{re.escape(t)}\b(?:\s+\d{{4}})?\s+{re.escape(num)}\b"
    return re.search(pat, lt) is not None


def _parse_cards(html: str, title: str, issue: str, cutoff: datetime) -> tuple[list[Sale], dict]:
    """Extract clean Sale rows from one results page. Returns (sales, reject_counts)."""
    from bs4 import BeautifulSoup

    soup = BeautifulSoup(html, "lxml")
    cards = soup.select("li.s-card, div.s-card, li.s-item, div.s-item")
    sales: list[Sale] = []
    rejects = {"placeholder": 0, "no_price": 0, "no_date": 0, "too_old": 0,
               "bad_title": 0, "wrong_book": 0, "no_item_id": 0}

    for card in cards:
        full = card.get_text(" ", strip=True)
        if "Shop on eBay" in full or len(full) < 10:
            rejects["placeholder"] += 1
            continue

        title_el = card.select_one(
            ".s-card__title, .s-item__title, [role=heading], .su-styled-text.primary"
        )
        card_title = (title_el.get_text(strip=True) if title_el else full)
        card_title = re.sub(r"^New Listing", "", card_title)
        # eBay glues screen-reader text ("Opens in a new window or tab") onto the title,
        # which fuses with the last word (e.g. "ReplicaOpens") and defeats word-boundary
        # filters. Strip it before any matching.
        card_title = re.sub(r"\s*Opens in a new window.*$", "", card_title, flags=re.I).strip()

        if _REJECT_TITLE_RE.search(card_title):
            rejects["bad_title"] += 1
            continue
        if not _matches_book(title, issue, card_title):
            rejects["wrong_book"] += 1
            continue

        price_el = card.select_one(".s-card__price, .s-item__price")
        price = _parse_price(price_el.get_text(" ", strip=True) if price_el else full)
        if price is None:
            rejects["no_price"] += 1
            continue

        sale_date = _parse_sold_date(full)
        if sale_date is None:
            rejects["no_date"] += 1
            continue
        if sale_date < cutoff:
            rejects["too_old"] += 1
            continue

        link = card.select_one("a[href*='/itm/']")
        href = link["href"] if link and link.has_attr("href") else ""
        id_match = _ITEM_ID_RE.search(href)
        if not id_match:
            rejects["no_item_id"] += 1
            continue
        item_id = id_match.group(1)

        sales.append(
            Sale(
                item_id=item_id,
                title=card_title,
                price=price,
                sale_date=sale_date,
                grade=_parse_grade(card_title),
                edition=_parse_edition(card_title),
                url=href.split("?")[0],
            )
        )

    return sales, rejects


# ---------------------------------------------------------------------------
# Optional Gemini title classifier
# ---------------------------------------------------------------------------
def _load_dotenv() -> None:
    """Load agent/.env into os.environ. ADK does this for the server; the standalone
    backfill script does not, so GOOGLE_API_KEY / FIRESTORE_PROJECT must be loaded here.
    Existing env vars win (so an inline FIRESTORE_PROJECT=... still overrides)."""
    env_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env")
    if not os.path.exists(env_path):
        return
    with open(env_path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            os.environ.setdefault(key.strip(), val.strip().strip('"').strip("'"))


def _gemini_client():
    from google import genai

    api_key = os.environ.get("GOOGLE_API_KEY")
    if not api_key:
        raise RuntimeError("GOOGLE_API_KEY not set (agent/.env) — required for --classify.")
    return genai.Client(api_key=api_key)


_CLASSIFIER_PROMPT = """You filter eBay sold-listing titles for a comic-book price tracker.
For each listing decide whether it is a genuine completed sale of THIS exact comic:

  TARGET: {book}
  Significance: {notes}

KEEP (keep=true) ONLY an original-printing copy of that exact issue — graded (CGC/CBCS/PGX)
or raw, any grade, any condition (including coverless/incomplete), newsstand or direct edition.

REJECT (keep=false):
  - Homage / tribute / reference covers of a DIFFERENT comic that merely name the key
  - Facsimile editions, reprints, reproductions, "newsprint replica", promo reprints
  - Modern variant or re-cover editions that are not the original printing
  - Collected editions: TPB, omnibus, Masterworks, Milestone, Epic Collection
  - Multi-book lots, sets, runs; merchandise (posters, magnets, shirts)
  - A different issue number

For kept listings set edition to "newsstand", "direct", or null if the title does not say.

Return ONLY a JSON array, one object per listing, each exactly:
{{"i": <index int>, "keep": <bool>, "edition": "newsstand"|"direct"|null, "reason": "<short>"}}

LISTINGS:
{listings}"""


def _classify_titles(client, book_label: str, notes: str, titles: list[str]) -> list[dict]:
    """Return a keep/edition/reason decision per title (aligned to input order).

    Batched to keep the call count low. Fails OPEN: if a batch errors or the model omits a
    row, that listing is kept (better a little residual noise than dropping a real sale).
    """
    import json as _json

    from google.genai import types

    results: list[dict] = [
        {"keep": True, "edition": None, "reason": "unclassified"} for _ in titles
    ]
    for start in range(0, len(titles), _CLASSIFIER_BATCH):
        batch = titles[start : start + _CLASSIFIER_BATCH]
        listings = "\n".join(f"{j}. {t}" for j, t in enumerate(batch))
        prompt = _CLASSIFIER_PROMPT.format(book=book_label, notes=notes or "—", listings=listings)
        try:
            resp = client.models.generate_content(
                model=_CLASSIFIER_MODEL,
                contents=prompt,
                config=types.GenerateContentConfig(
                    temperature=0,
                    thinking_config=types.ThinkingConfig(thinking_budget=0),
                    response_mime_type="application/json",
                ),
            )
            by_i = {int(d["i"]): d for d in _json.loads(resp.text)}
        except Exception as exc:  # noqa: BLE001 — fail open, flag the reason
            for j in range(len(batch)):
                results[start + j] = {
                    "keep": True, "edition": None,
                    "reason": f"classifier-error:{type(exc).__name__}",
                }
            continue
        for j in range(len(batch)):
            d = by_i.get(j, {})
            ed = d.get("edition")
            results[start + j] = {
                "keep": bool(d.get("keep", True)),
                "edition": ed if ed in ("newsstand", "direct") else None,
                "reason": str(d.get("reason", ""))[:80],
            }
    return results


def classify_sales(
    client, title: str, issue: str, publisher: str, notes: str, sales: list[Sale]
) -> tuple[list[Sale], list[tuple[str, str]]]:
    """Filter `sales` through the Gemini classifier. Returns (kept, dropped) where dropped is
    a list of (title, reason) for transparency in dry-run output. Edition from the classifier
    overrides the regex guess when the model is confident."""
    label = f"{title} {issue}".strip() + (f" ({publisher})" if publisher else "")
    decisions = _classify_titles(client, label, notes, [s.title for s in sales])
    kept: list[Sale] = []
    dropped: list[tuple[str, str]] = []
    for sale, d in zip(sales, decisions):
        if d["keep"]:
            if d["edition"]:
                sale.edition = d["edition"]
            kept.append(sale)
        else:
            dropped.append((sale.title, d["reason"]))
    return kept, dropped


def scrape_book(client: EbayClient, title: str, issue: str, days: int, max_pages: int) -> list[Sale]:
    """Scrape up to `days` of sold listings for one book, de-duplicated by eBay item id."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    query = _search_query(title, issue)
    by_id: dict[str, Sale] = {}

    for page in range(1, max_pages + 1):
        html = client.get_page(query, page)
        if not html:
            print(f"    page {page}: blocked by eBay after retries — skipping rest of book")
            break
        sales, rejects = _parse_cards(html, title, issue, cutoff)
        for s in sales:
            by_id.setdefault(s.item_id, s)
        print(
            f"    page {page}: kept {len(sales)} "
            f"(rejects: { {k: v for k, v in rejects.items() if v} })"
        )
        # Newest-sold-first: once a page is all older than the window, later pages are too.
        if rejects["too_old"] > 0 and not sales:
            break
        if len(sales) == 0:
            break
        time.sleep(_REQUEST_PAUSE_S)

    return sorted(by_id.values(), key=lambda s: s.sale_date)


def _newest_sale_date(book_ref) -> datetime | None:
    """The most recent stored sale_date for a book — the incremental high-water mark."""
    docs = list(
        book_ref.collection(_SALES)
        .order_by("sale_date", direction=firestore.Query.DESCENDING)
        .limit(1)
        .stream()
    )
    if not docs:
        return None
    d = (docs[0].to_dict() or {}).get("sale_date")
    return d if isinstance(d, datetime) else None


def _effective_days(book_ref, fallback_days: int, incremental: bool) -> tuple[int, str]:
    """Decide how many days back to scrape for one book.

    Fixed-window mode returns `fallback_days`. Incremental mode reaches back to a couple of
    days before the newest sale we already stored (so irregular run gaps are covered, and
    idempotent ids make the overlap free), clamped to eBay's ~90-day retention; a book with
    no prior sales falls back to the full window.
    """
    if not incremental:
        return fallback_days, f"{fallback_days}d window"
    newest = _newest_sale_date(book_ref)
    if newest is None:
        return fallback_days, f"full {fallback_days}d (no prior sales)"
    gap_days = (datetime.now(timezone.utc) - newest).days + _INCREMENTAL_OVERLAP_DAYS
    days = max(1, min(gap_days, _EBAY_RETENTION_DAYS))
    note = f"incremental since {newest:%Y-%m-%d} (~{days}d)"
    if gap_days > _EBAY_RETENTION_DAYS:
        note += " — gap exceeds eBay's 90d retention; older sales unrecoverable"
    return days, note


def _write_sales(book_ref, sales: list[Sale]) -> int:
    written = 0
    for s in sales:
        book_ref.collection(_SALES).document(s.sale_id).set(
            {
                "price": s.price,
                "grade": s.grade,
                "raw_or_graded": s.raw_or_graded,
                "edition": s.edition,
                "source": "ebay",
                "url": s.url,
                "sale_date": s.sale_date,
            }
        )
        written += 1
    return written


def _summarize(sales: list[Sale]) -> str:
    if not sales:
        return "no sales"
    graded = [s for s in sales if s.grade is not None]
    prices = [s.price for s in sales]
    span = f"{sales[0].sale_date:%b %d} – {sales[-1].sale_date:%b %d}"
    ns = sum(1 for s in sales if s.edition == "newsstand")
    direct = sum(1 for s in sales if s.edition == "direct")
    return (
        f"{len(sales)} sales ({len(graded)} graded / {len(sales) - len(graded)} raw), "
        f"${min(prices):,.0f}–${max(prices):,.0f}, {span}"
        f" | edition: {ns} newsstand / {direct} direct / {len(sales) - ns - direct} unknown"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Backfill eBay sold listings into Firestore.")
    parser.add_argument("--commit", action="store_true",
                        help="Write to Firestore. Without this flag the script is a dry run.")
    parser.add_argument("--days", type=int, default=90,
                        help="Days of sold history to capture (default 90). In --incremental "
                             "mode this is the fallback window for books with no prior sales.")
    parser.add_argument("--incremental", action="store_true",
                        help="Per book, scrape only since (newest stored sale - 2d), so "
                             "irregular run intervals leave no gap. Books with no sales yet "
                             "fall back to the full --days window. Ideal for routine refreshes.")
    parser.add_argument("--max-pages", type=int, default=4,
                        help="Max result pages to fetch per book (default 4).")
    parser.add_argument("--sample", type=int, default=8,
                        help="How many parsed sales to print per book in dry-run (default 8).")
    parser.add_argument("--classify", action="store_true",
                        help="Run the Gemini title classifier to drop homage/variant/reprint "
                             "listings the heuristics can't catch (needs GOOGLE_API_KEY).")
    parser.add_argument("--book", default="",
                        help="Scrape only the book whose id or title matches this (substring, "
                             "case-insensitive). The low-rate, run-it-per-book manual mode.")
    parser.add_argument("--book-interval", type=int, default=900,
                        help="Seconds to wait between books in a multi-book sweep (default 900 "
                             "= 15 min, to stay under eBay's rate-limit). Use 0 for quick "
                             "dry-runs; irrelevant with --book.")
    args = parser.parse_args()

    _load_dotenv()  # make GOOGLE_API_KEY / FIRESTORE_PROJECT available to the standalone script

    mode = "COMMIT — writing to Firestore" if args.commit else "DRY RUN — no writes"
    window = "incremental (since last scrape)" if args.incremental else f"last {args.days} days"
    extra = " | Gemini classifier ON" if args.classify else ""
    print(f"eBay sold-listings backfill | {mode} | {window}{extra}\n")

    fs = db()
    books = list(fs.collection(_WATCHLIST).stream())
    if not books:
        print("Watchlist is empty — add books before backfilling.")
        return

    if args.book:
        needle = args.book.lower()
        books = [d for d in books
                 if needle in d.id.lower() or needle in (d.to_dict() or {}).get("title", "").lower()]
        if not books:
            print(f"No watchlist book matches '{args.book}'.")
            return
        if len(books) > 1:
            print(f"'{args.book}' matches multiple books: {[d.id for d in books]}. Be more specific.")
            return

    gemini = _gemini_client() if args.classify else None
    client = EbayClient()
    grand_total = 0

    for i, doc in enumerate(books):
        if i:
            print(f"  … waiting {args.book_interval}s before next book (rate-limit spacing)")
            time.sleep(args.book_interval)
            client.warm()  # fresh session per book
        data = doc.to_dict() or {}
        title, issue = data.get("title", ""), data.get("issue", "")
        days, window_note = _effective_days(doc.reference, args.days, args.incremental)
        print(f"• {title} {issue}  (book_id={doc.id})  [{window_note}]")
        try:
            sales = scrape_book(client, title, issue, days, args.max_pages)
        except EbayBlockedError as exc:
            # The IP is flagged — every remaining book would hit the same wall. Stop cleanly.
            print(f"    BLOCKED: {exc}\n\nAborting run. Re-run after the cool-down.")
            return
        except Exception as exc:  # noqa: BLE001
            print(f"    ERROR scraping: {type(exc).__name__}: {exc}\n")
            continue

        if gemini is not None and sales:
            kept, dropped = classify_sales(gemini, title, issue,
                                           data.get("publisher", ""), data.get("notes", ""), sales)
            print(f"    classifier: kept {len(kept)}, dropped {len(dropped)}")
            for t, reason in dropped[:5]:
                print(f"       drop: {t[:56]}  | {reason}")
            sales = kept

        print(f"    => {_summarize(sales)}")
        for s in sales[-args.sample:]:
            grade = f"{s.grade:>4}" if s.grade is not None else " raw"
            ed = {"newsstand": "NS", "direct": "DI"}.get(s.edition, "  ")
            print(f"       {s.sale_date:%Y-%m-%d}  {grade}  {ed}  ${s.price:>10,.2f}  {s.title[:56]}")

        if args.commit and sales:
            n = _write_sales(doc.reference, sales)
            grand_total += n
            print(f"    wrote {n} sales docs")
        print()

    if args.commit:
        print(f"Backfill complete. Wrote {grand_total} sales documents.")
    else:
        print("Dry run complete. Re-run with --commit to persist.")


if __name__ == "__main__":
    main()

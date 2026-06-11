"""
ADK function tool exposing per-book price history from the Firestore `sales` subcollection
(Phase 3). Reads the real eBay sold-listing history landed by tools/backfill_sales.py.

Firestore layout (per docs/CPCD.md §9):

    watchlist/{bookId}/sales/{saleId}
      price: float
      sale_date: timestamp
      source: "ebay" | "manual"
      url: str | None
      raw_or_graded: "raw" | "graded"
      grade: float | None          # per-sale grade — the basis for grade-level analysis
      edition: "newsstand" | "direct" | None   # additive beyond CPCD §9 (backfill_sales.py)

Prices are NOT stored flat on the comic document; everything here is derived on read from the
`sales` subcollection. The agent calls this tool, then composes A2UI (and, later, the
visualization catalog: Sparkline / GradeTierMatrix / SmallMultiplesGrid) from what it returns.
"""

import logging
from datetime import datetime, timedelta, timezone
from statistics import median

from google.cloud import firestore

from ..firestore_client import db

logger = logging.getLogger(__name__)

_WATCHLIST = "watchlist"
_SALES = "sales"
_DEFAULT_DAYS = 90


def _tool_error(action: str, exc: Exception) -> dict:
    """Build a structured error result instead of raising.

    A raised exception aborts the ADK turn silently — the A2A client receives no content and
    the app renders nothing. Returning {status: "error", ...} lets the model receive the
    failure, continue its turn, and render a graceful message.
    """
    logger.exception("price_history tool failed while trying to %s", action)
    return {
        "status": "error",
        "error": f"Could not {action}: {type(exc).__name__}: {exc}",
    }


def _iso(value) -> str | None:
    return value.isoformat() if hasattr(value, "isoformat") else None


def _stats(prices: list[float]) -> dict:
    """min / max / median / average for a non-empty price list (rounded for display)."""
    return {
        "count": len(prices),
        "min": round(min(prices), 2),
        "max": round(max(prices), 2),
        "median": round(median(prices), 2),
        "avg": round(sum(prices) / len(prices), 2),
    }


def get_price_history(book_id: str, days: int = _DEFAULT_DAYS, grade: float = 0.0) -> dict:
    """Fetch the recent sale-price history for one watchlist comic.

    Call this when the user asks about a comic's price, value, trend, or how a grade is
    selling. Resolve book_id via get_watchlist first if the user names the comic by
    title/issue. The data is real eBay sold-listing history; render only what this returns.

    Args:
        book_id: The comic's document id (from get_watchlist), e.g. "new-mutants-98".
        days: Look-back window in days. Defaults to 90 (the backfill window).
        grade: Optional exact grade filter, e.g. 9.8 to see only CGC/CBCS 9.8 sales.
            Use 0 (default) for all sales across every grade and raw copies.

    Returns:
        A dict with the book, the window, an overall price summary, a per-grade breakdown
        (graded sales grouped by grade, plus a raw bucket), and the chronological list of
        sales (oldest first) for charting. On failure, returns
        {"status": "error", "error": "..."} instead of raising.
    """
    try:
        days = days if days and days > 0 else _DEFAULT_DAYS
        ref = db().collection(_WATCHLIST).document(book_id)
        snap = ref.get()
        if not snap.exists:
            return {"status": "not_found", "book_id": book_id}

        book = snap.to_dict() or {}
        cutoff = datetime.now(timezone.utc) - timedelta(days=days)

        # Window-filter in the query; grade-filter in Python (a sale's grade may be null).
        docs = (
            ref.collection(_SALES)
            .where(filter=firestore.FieldFilter("sale_date", ">=", cutoff))
            .order_by("sale_date")
            .stream()
        )

        sales: list[dict] = []
        for d in docs:
            s = d.to_dict() or {}
            if grade > 0 and s.get("grade") != grade:
                continue
            price = s.get("price")
            if price is None:
                continue
            sales.append(
                {
                    "sale_date": _iso(s.get("sale_date")),
                    "price": price,
                    "grade": s.get("grade"),
                    "raw_or_graded": s.get("raw_or_graded"),
                    "edition": s.get("edition"),
                    "source": s.get("source"),
                    "url": s.get("url"),
                }
            )

        result = {
            "status": "ok",
            "book_id": book_id,
            "title": book.get("title"),
            "issue": book.get("issue"),
            "days": days,
            "grade_filter": grade if grade > 0 else None,
            "from": _iso(cutoff),
            "to": _iso(datetime.now(timezone.utc)),
            "count": len(sales),
            "sales": sales,
        }
        if not sales:
            result["summary"] = None
            result["by_grade"] = []
            result["raw"] = None
            return result

        prices = [s["price"] for s in sales]
        first_price, last_price = sales[0]["price"], sales[-1]["price"]
        summary = _stats(prices)
        summary["first_price"] = round(first_price, 2)
        summary["last_price"] = round(last_price, 2)
        summary["change_pct"] = (
            round((last_price - first_price) / first_price * 100, 1) if first_price else None
        )
        summary["graded_count"] = sum(1 for s in sales if s["grade"] is not None)
        summary["raw_count"] = sum(1 for s in sales if s["grade"] is None)
        result["summary"] = summary

        # Per-grade breakdown (graded sales grouped by exact grade, highest first) — feeds the
        # future GradeTierMatrix. Raw copies get their own bucket.
        grades: dict[float, list[float]] = {}
        raw_prices: list[float] = []
        for s in sales:
            if s["grade"] is None:
                raw_prices.append(s["price"])
            else:
                grades.setdefault(s["grade"], []).append(s["price"])
        result["by_grade"] = [
            {"grade": g, **_stats(p)} for g, p in sorted(grades.items(), reverse=True)
        ]
        result["raw"] = _stats(raw_prices) if raw_prices else None

        return result
    except Exception as exc:  # noqa: BLE001 — surface to the model, don't abort the turn
        return _tool_error(f"read price history for {book_id}", exc)

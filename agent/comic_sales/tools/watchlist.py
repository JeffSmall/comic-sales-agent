"""
ADK function tools backing the persistent Firestore watchlist (Phase 2).

Firestore layout (per docs/CPCD.md §9 — single-user v1, no userId path layer):

    watchlist/{bookId}
      title, issue, publisher: str
      raw_or_graded: "raw" | "graded"
      grader: "CGC" | "CBCS" | None
      grade: float | None
      notes: str
    watchlist/{bookId}/sales/{saleId}
      price: float
      sale_date: timestamp
      source: "ebay" | "manual"
      url: str | None
      raw_or_graded: "raw" | "graded"
      grade: float | None    # per-sale grade (Phase 3 grade-level analysis)

The agent calls these tools, then composes A2UI from the returned data. Prices are NOT
stored as a flat array on the comic document — `recent_prices`/`last_sale` are derived
on read from the `sales` subcollection purely for display.
"""

import logging
import re
import uuid
from datetime import datetime, timezone

from google.cloud import firestore

from ..firestore_client import db

logger = logging.getLogger(__name__)

_WATCHLIST = "watchlist"
_SALES = "sales"
_RECENT_SALES_LIMIT = 5


def _tool_error(action: str, exc: Exception) -> dict:
    """Build a structured error result instead of raising.

    A raised exception aborts the ADK turn silently — the A2A client receives no content
    and the app renders nothing. Returning {status: "error", ...} instead lets the model
    receive the failure, continue its turn, and render a graceful message to the user.
    """
    logger.exception("watchlist tool failed while trying to %s", action)
    return {
        "status": "error",
        "error": f"Could not {action}: {type(exc).__name__}: {exc}",
    }


def _slugify(title: str, issue: str) -> str:
    """Derive a stable, human-readable document id from title + issue.

    "Amazing Fantasy" + "#15" -> "amazing-fantasy-15"
    """
    raw = f"{title} {issue}".lower()
    slug = re.sub(r"[^a-z0-9]+", "-", raw).strip("-")
    return slug or uuid.uuid4().hex


def _recent_sales(book_ref: firestore.DocumentReference) -> list[dict]:
    """Return up to _RECENT_SALES_LIMIT sales, oldest-first (chronological for display)."""
    docs = list(
        book_ref.collection(_SALES)
        .order_by("sale_date", direction=firestore.Query.DESCENDING)
        .limit(_RECENT_SALES_LIMIT)
        .stream()
    )
    sales = []
    for d in docs:
        data = d.to_dict() or {}
        sale_date = data.get("sale_date")
        sales.append(
            {
                "price": data.get("price"),
                "grade": data.get("grade"),
                "source": data.get("source"),
                "sale_date": sale_date.isoformat() if hasattr(sale_date, "isoformat") else None,
            }
        )
    sales.reverse()  # chronological: oldest -> newest
    return sales


def get_watchlist() -> dict:
    """Fetch the user's full comic watchlist from Firestore.

    Call this before displaying the watchlist or answering any question about which
    comics the user is tracking. Returns every comic with its derived recent price
    history. Never invent comics — render only what this returns.

    Returns:
        A dict {"comics": [...]} where each comic has: book_id, title, issue,
        publisher, grader, grade, raw_or_graded, notes, last_sale, and recent_prices
        (a chronological list of recent sale prices, oldest first).
        On failure, returns {"status": "error", "error": "..."} instead of raising.
    """
    try:
        comics = []
        for doc in db().collection(_WATCHLIST).stream():
            data = doc.to_dict() or {}
            sales = _recent_sales(doc.reference)
            recent_prices = [s["price"] for s in sales if s["price"] is not None]
            comics.append(
                {
                    "book_id": doc.id,
                    "title": data.get("title"),
                    "issue": data.get("issue"),
                    "publisher": data.get("publisher"),
                    "grader": data.get("grader"),
                    "grade": data.get("grade"),
                    "raw_or_graded": data.get("raw_or_graded"),
                    "notes": data.get("notes"),
                    "last_sale": recent_prices[-1] if recent_prices else None,
                    "recent_prices": recent_prices,
                }
            )
        comics.sort(key=lambda c: (c.get("title") or "", c.get("issue") or ""))
        return {"comics": comics}
    except Exception as exc:  # noqa: BLE001 — surface to the model, don't abort the turn
        return _tool_error("read the watchlist", exc)


def upsert_comic(
    title: str,
    issue: str,
    book_id: str = "",
    publisher: str = "",
    grader: str = "",
    grade: float = 0.0,
    raw_or_graded: str = "",
    notes: str = "",
) -> dict:
    """Create a new comic in the watchlist, or update an existing one.

    Call this before confirming any add or edit. If editing an existing comic, pass its
    book_id. To add a new comic, leave book_id empty and a stable id will be derived from
    the title and issue.

    This is a partial update: only the fields you pass are written. Omitted (empty/zero)
    optional fields are left unchanged on an existing comic, so you can edit one field
    without clobbering the rest.

    Args:
        title: Comic title, e.g. "Amazing Fantasy". Required.
        issue: Issue identifier, e.g. "#15". Required.
        book_id: Existing document id to update. Empty to create a new comic.
        publisher: Publisher, e.g. "Marvel".
        grader: "CGC", "CBCS", or empty for a raw (ungraded) copy.
        grade: Numeric grade of the owned copy, e.g. 9.8. Use 0 to leave unchanged.
        raw_or_graded: "graded" or "raw".
        notes: Free-text notes, e.g. "1st appearance Spider-Man".

    Returns:
        A dict with status "created" or "updated" and the written comic record.
        On failure, returns {"status": "error", "error": "..."} instead of raising.
    """
    try:
        is_new = not book_id
        if is_new:
            book_id = _slugify(title, issue)

        ref = db().collection(_WATCHLIST).document(book_id)
        existed = ref.get().exists

        # Partial update: only include fields that were actually provided, so editing one
        # field never overwrites others with empty defaults. title/issue are always set.
        record: dict = {"title": title, "issue": issue}
        if publisher:
            record["publisher"] = publisher
        if grader:
            record["grader"] = grader
        if grade > 0:
            record["grade"] = grade
        if raw_or_graded:
            record["raw_or_graded"] = raw_or_graded
        elif is_new:
            record["raw_or_graded"] = "graded"  # sensible default for a brand-new comic
        if notes:
            record["notes"] = notes

        ref.set(record, merge=True)

        return {
            "status": "updated" if existed else "created",
            "comic": {"book_id": book_id, **record},
        }
    except Exception as exc:  # noqa: BLE001 — surface to the model, don't abort the turn
        return _tool_error(f"save {title} {issue}".strip(), exc)


def remove_comic(book_id: str) -> dict:
    """Remove a comic (and all its sales) from the watchlist.

    Call this before confirming a removal. Look up the book_id via get_watchlist first
    if you only know the title/issue.

    Args:
        book_id: The document id of the comic to delete.

    Returns:
        A dict with status "removed" (or "not_found") and the book_id.
        On failure, returns {"status": "error", "error": "..."} instead of raising.
    """
    try:
        ref = db().collection(_WATCHLIST).document(book_id)
        if not ref.get().exists:
            return {"status": "not_found", "book_id": book_id}

        # Delete the sales subcollection first (Firestore does not cascade).
        for sale in ref.collection(_SALES).stream():
            sale.reference.delete()
        ref.delete()

        return {"status": "removed", "book_id": book_id}
    except Exception as exc:  # noqa: BLE001 — surface to the model, don't abort the turn
        return _tool_error(f"remove {book_id}", exc)


def add_sale(
    book_id: str,
    price: float,
    grade: float = 0.0,
    source: str = "manual",
    url: str = "",
    raw_or_graded: str = "graded",
) -> dict:
    """Record a single completed sale for a comic.

    Call this when the user reports a sale price they want tracked. The sale date is
    recorded as now. Each sale stores its own grade so grade-level trends can be analyzed.

    Args:
        book_id: The comic this sale belongs to (from get_watchlist).
        price: Sale price in dollars.
        grade: Numeric grade of the copy that sold, e.g. 9.8. Use 0 for raw.
        source: "manual" (user-entered) or "ebay".
        url: Optional listing URL.
        raw_or_graded: "graded" or "raw".

    Returns:
        A dict with status "recorded", the sale_id, and the stored sale.
        On failure, returns {"status": "error", "error": "..."} instead of raising.
    """
    try:
        ref = db().collection(_WATCHLIST).document(book_id)
        if not ref.get().exists:
            return {"status": "not_found", "book_id": book_id}

        sale = {
            "price": price,
            "grade": grade if grade > 0 else None,
            "source": source or "manual",
            "url": url or None,
            "raw_or_graded": raw_or_graded or "graded",
            "sale_date": datetime.now(timezone.utc),
        }
        sale_id = uuid.uuid4().hex
        ref.collection(_SALES).document(sale_id).set(sale)

        sale["sale_date"] = sale["sale_date"].isoformat()
        return {"status": "recorded", "sale_id": sale_id, "sale": sale}
    except Exception as exc:  # noqa: BLE001 — surface to the model, don't abort the turn
        return _tool_error(f"record a sale for {book_id}", exc)

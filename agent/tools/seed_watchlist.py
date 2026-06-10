"""
One-time, idempotent seed of the Phase-1 hardcoded watchlist into Firestore (Phase 2).

Migrates the two books that used to live as a hardcoded list in agent.py into the
CPCD §9 schema: a `watchlist/{bookId}` document plus per-sale `sales/{saleId}` documents
(the old flat `recent_prices` array is exploded into individual sales, each carrying the
owned grade and a synthesized weekly sale_date). This gives Phase 2 real display data and
Phase 3 real per-grade sales to render against.

Run once, with the agent venv active and ADC configured:

    cd agent && source .venv/bin/activate
    FIRESTORE_PROJECT=<project-id> python tools/seed_watchlist.py

Re-running is safe: document ids are deterministic, so it upserts rather than duplicates.
"""

import os
import sys
from datetime import datetime, timedelta, timezone

# Allow running as a plain script: make the comic_sales package importable.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from comic_sales.firestore_client import db  # noqa: E402
from comic_sales.tools.watchlist import _slugify  # noqa: E402

# The Phase-1 hardcoded watchlist. recent_prices are chronological (oldest -> newest).
SEED = [
    {
        "title": "Amazing Fantasy",
        "issue": "#15",
        "publisher": "Marvel",
        "grade": 9.8,
        "grader": "CGC",
        "raw_or_graded": "graded",
        "recent_prices": [18500, 19200, 17800, 21000, 20500],
        "notes": "1st appearance Spider-Man",
    },
    {
        "title": "Incredible Hulk",
        "issue": "#1",
        "publisher": "Marvel",
        "grade": 6.0,
        "grader": "CGC",
        "raw_or_graded": "graded",
        "recent_prices": [9800, 10200, 9500, 11000],
        "notes": "1st appearance Hulk",
    },
]


def seed() -> None:
    client = db()
    now = datetime.now(timezone.utc)

    for book in SEED:
        book_id = _slugify(book["title"], book["issue"])
        ref = client.collection("watchlist").document(book_id)
        ref.set(
            {
                "title": book["title"],
                "issue": book["issue"],
                "publisher": book["publisher"],
                "grader": book["grader"],
                "grade": book["grade"],
                "raw_or_graded": book["raw_or_graded"],
                "notes": book["notes"],
            },
            merge=True,
        )

        prices = book["recent_prices"]
        n = len(prices)
        for i, price in enumerate(prices):
            # Oldest price is furthest in the past; newest is most recent (1 week ago).
            weeks_ago = n - i
            sale_date = now - timedelta(weeks=weeks_ago)
            sale_id = f"{book_id}-seed-{i}"
            ref.collection("sales").document(sale_id).set(
                {
                    "price": float(price),
                    "grade": book["grade"],
                    "raw_or_graded": book["raw_or_graded"],
                    "source": "manual",
                    "url": None,
                    "sale_date": sale_date,
                }
            )

        print(f"  seeded {book['title']} {book['issue']} -> {book_id} ({n} sales)")

    print("Seed complete.")


if __name__ == "__main__":
    seed()

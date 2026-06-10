"""
Firestore client singleton for the comic sales agent (Phase 2).

Auth is via Application Default Credentials (ADC) — set up locally with
`gcloud auth application-default login`. No service-account key file is used.

The target project is read from the FIRESTORE_PROJECT env var (set in agent/.env,
loaded by ADK alongside GOOGLE_API_KEY).
"""

import os

from google.cloud import firestore

_db: firestore.Client | None = None


def db() -> firestore.Client:
    """Return a lazily-initialized, process-wide Firestore client."""
    global _db
    if _db is None:
        project = os.environ.get("FIRESTORE_PROJECT")
        if not project:
            raise RuntimeError(
                "FIRESTORE_PROJECT is not set. Add it to agent/.env "
                "(the GCP project id that hosts the watchlist Firestore database)."
            )
        _db = firestore.Client(project=project)
    return _db

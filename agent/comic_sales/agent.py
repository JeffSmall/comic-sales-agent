"""
Spike A — Minimal ADK agent that emits A2UI for a hardcoded comic watchlist.

Goal: prove the ADK → A2UI pipeline works locally via `adk web`.
No Firestore, no custom catalog yet — uses BasicCatalog + hardcoded data.
"""

from google.adk.agents import Agent
from a2ui.schema.manager import A2uiSchemaManager
from a2ui.schema.constants import VERSION_0_9_1
from a2ui.basic_catalog.provider import BasicCatalog

# ---------------------------------------------------------------------------
# Hardcoded watchlist — replaces Firestore for Spike A
# ---------------------------------------------------------------------------
WATCHLIST = [
    {
        "title": "Amazing Fantasy",
        "issue": "#15",
        "publisher": "Marvel",
        "grade": 9.8,
        "grader": "CGC",
        "recent_prices": [18500, 19200, 17800, 21000, 20500],
        "last_sale": 20500,
        "notes": "1st appearance Spider-Man",
    },
    {
        "title": "Incredible Hulk",
        "issue": "#1",
        "publisher": "Marvel",
        "grade": 6.0,
        "grader": "CGC",
        "recent_prices": [9800, 10200, 9500, 11000],
        "last_sale": 11000,
        "notes": "1st appearance Hulk",
    },
]

# ---------------------------------------------------------------------------
# A2UI system prompt
# ---------------------------------------------------------------------------
_schema_mgr = A2uiSchemaManager(
    version=VERSION_0_9_1,
    catalogs=[BasicCatalog.get_config(version=VERSION_0_9_1)],
)

_system_prompt = _schema_mgr.generate_system_prompt(
    role_description=(
        "You are a comic book sales agent. You help the user track and analyze "
        "their graded and raw comic watchlist. When responding with data, always "
        "use A2UI structured components — never plain text lists. "
        "Use Card, Row, Column, and Text components to present comic information "
        "in a dense, data-first layout. Right-align prices. "
        "Prefer structured UI over prose."
    ),
    workflow_description=(
        "When the user asks about their watchlist or a specific comic, respond "
        "with an A2UI block containing the relevant data. "
        "Always include: title, issue, grade, grader, and last sale price. "
        "If multiple comics match, show all of them."
    ),
    ui_description=(
        "Layout: vertical Column of Cards. Each Card shows one comic: "
        "title+issue in a bold Text on the left, grade+grader in a smaller Text, "
        "and last sale price right-aligned. Keep it dense — no decorative elements."
    ),
    include_schema=True,
    include_examples=False,
)

# Inject the hardcoded watchlist into the system prompt so the agent
# can reason about it without tool calls in Spike A.
_watchlist_block = "\n\n## Current Watchlist (hardcoded for Spike A)\n"
for book in WATCHLIST:
    prices_str = ", ".join(f"${p:,}" for p in book["recent_prices"])
    _watchlist_block += (
        f"- {book['title']} {book['issue']} | {book['grader']} {book['grade']} "
        f"| Last sale: ${book['last_sale']:,} | Recent: {prices_str} | {book['notes']}\n"
    )

_INSTRUCTION = _system_prompt + _watchlist_block

# ADK template-substitutes any {…} tokens in a plain string instruction,
# which breaks A2UI's embedded JSON schema. Using a callable bypasses that.
def instruction(_context) -> str:
    return _INSTRUCTION

# ---------------------------------------------------------------------------
# Root agent
# ---------------------------------------------------------------------------
root_agent = Agent(
    name="comic_sales_agent",
    model="gemini-2.5-flash",
    description="Comic book sales tracking agent — emits A2UI catalog payloads.",
    instruction=instruction,
)

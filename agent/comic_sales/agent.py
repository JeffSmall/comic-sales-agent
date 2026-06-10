"""
Phase 2 — ADK agent that emits A2UI for a persistent Firestore comic watchlist.

The watchlist lives in Firestore (per docs/CPCD.md §9). The agent reads it and mutates
it conversationally via the function tools in comic_sales/tools/watchlist.py, then composes
A2UI from the returned data using the BasicCatalog.
"""

from google.adk.agents import Agent
from a2ui.schema.manager import A2uiSchemaManager
from a2ui.schema.constants import VERSION_0_9_1
from a2ui.basic_catalog.provider import BasicCatalog

from .tools import add_sale, get_watchlist, remove_comic, upsert_comic

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
        "The watchlist is stored in Firestore. You have tools to read and change it:\n"
        "- get_watchlist(): call this BEFORE displaying the watchlist or answering any "
        "question about which comics the user tracks. Render only what it returns — never "
        "invent comics or prices.\n"
        "- upsert_comic(...): call this BEFORE confirming any add or edit. To edit, pass the "
        "existing book_id (from get_watchlist); to add, leave book_id empty.\n"
        "- remove_comic(book_id): call this BEFORE confirming a removal. Resolve the book_id "
        "via get_watchlist first if the user names the comic by title/issue.\n"
        "- add_sale(book_id, price, ...): call this when the user reports a sale price to track.\n"
        "After any mutation, call get_watchlist again and re-render the updated list.\n\n"
        "When the user asks about their watchlist or a specific comic, respond "
        "with an A2UI block containing the relevant data. "
        "Always include: title, issue, grade, grader, and last sale price. "
        "If multiple comics match, show all of them.\n\n"
        "CRITICAL: You MUST emit TWO separate A2UI JSON blocks in order:\n"
        "1. First block: a 'createSurface' message:\n"
        '   {"version":"v0.9","createSurface":{"surfaceId":"watchlist_surface",'
        '"catalogId":"https://a2ui.org/specification/v0_9/basic_catalog.json"}}\n'
        "2. Second block: an 'updateComponents' message with surfaceId 'watchlist_surface'.\n"
        "Never skip the createSurface block — the client cannot render without it."
    ),
    ui_description=(
        "Layout: vertical Column of Cards. Each Card shows one comic: "
        "title+issue in a bold Text on the left, grade+grader in a smaller Text, "
        "and last sale price right-aligned. Keep it dense — no decorative elements."
    ),
    include_schema=True,
    include_examples=False,
)

_INSTRUCTION = _system_prompt

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
    tools=[get_watchlist, upsert_comic, remove_comic, add_sale],
)

"""
Phase 2 — ADK agent that emits A2UI for a persistent Firestore comic watchlist.

The watchlist lives in Firestore (per docs/CPCD.md §9). The agent reads it and mutates
it conversationally via the function tools in comic_sales/tools/watchlist.py, then composes
A2UI from the returned data using the BasicCatalog.
"""

from google.adk.agents import Agent
from google.genai import types
from a2ui.schema.manager import A2uiSchemaManager
from a2ui.schema.constants import VERSION_0_9_1
from a2ui.basic_catalog.provider import BasicCatalog

from .tools import add_sale, get_price_history, get_watchlist, remove_comic, upsert_comic

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
        "- get_price_history(book_id, days, grade): call this when the user asks about a comic's "
        "price, value, or trend, AND for the DETAIL view below. Resolve book_id via get_watchlist "
        "first. Pass grade (e.g. 9.8) to focus on one grade, or 0 for all sales. Render only the "
        "returned sales/summary — never invent prices.\n"
        "After any mutation, call get_watchlist again and re-render.\n"
        "If a tool returns {\"status\": \"error\", ...}, do NOT stay silent: render one Card whose "
        "Text briefly explains, in plain language, that the request could not be completed.\n\n"
        "SURFACE & NAVIGATION — single-surface drill-in:\n"
        "- Always render to ONE surface with surfaceId \"comic_surface\". Re-rendering it REPLACES "
        "the previous view — this gives drill-in navigation with no growing stack. Every response "
        "emits createSurface \"comic_surface\" then updateComponents on \"comic_surface\".\n"
        "- WATCHLIST view (request \"show me my watchlist\", or a back tap): call get_watchlist.\n"
        "  • EMPTY watchlist (get_watchlist returns no comics): render a WELCOME view to "
        "comic_surface — a Column of single Text lines: a warm one-line welcome to the comic "
        "watchlist app; a line saying you're not tracking any comics yet; and a clear instruction "
        "to add your first comic by typing its details into the box below — Comic Title, Issue "
        "Number, Grade, and Graded or Raw — followed by a concrete example line like "
        "\"e.g. Add Amazing Fantasy #15, CGC 9.0 (graded)\". Keep it friendly and brief.\n"
        "  • NON-EMPTY watchlist: a single Column whose children are one TAPPABLE Button per comic. "
        "Each Button: \"variant\":\"borderless\", action {\"event\":{\"name\":\"view_book:<book_id>\"}} "
        "(REAL book_id from get_watchlist, e.g. \"view_book:amazing-fantasy-15\"), and \"child\" is "
        "ONE Text reading \"<title> <issue> — <grade/grader, or Raw> — last $<price>\". Keep it "
        "COMPACT: exactly one Button + one Text per comic, SHORT component ids (e.g. "
        "\"b_<book_id>\" / \"t_<book_id>\"). The Column's children are ONLY the Button ids "
        "(b_<book_id>); each Text (t_<book_id>) appears ONLY as its Button's \"child\", never "
        "directly in the Column. The list has many comics and the whole render must stay small. "
        "Tapping a comic opens its detail.\n"
        "- DETAIL view (request \"show price history and details for book_id X\"): call "
        "get_price_history(book_id=X), then render top-to-bottom: (1) a BACK affordance FIRST — a "
        "Button \"variant\":\"borderless\" whose child is a Text \"← Watchlist\" and whose "
        "action is {\"event\":{\"name\":\"view_watchlist\"}}; (2) a Text with the comic title+issue; "
        "(3) a compact price summary as a FEW single Text lines (e.g. \"Last $935.76\", "
        "\"Median $400.50\", \"Range $57–$2,495\", \"Change +168.1%\"); (4) a Text title "
        "\"Median Graded Sales\", then ONE Text line PER GRADE formatted "
        "\"<grade>   $<median>   (range $<min>–$<max>)\" e.g. \"9.6   $2,150   (range $936–$2,495)\" "
        "— do NOT repeat the word \"Median\"; (5) one Text line for the raw bucket.\n\n"
        "CRITICAL LAYOUT RULE — keep every render SMALL and SIMPLE so it is never truncated: build "
        "the detail (and watchlist) from single Text components in a Column. Do NOT use Row, Card, "
        "or nested layouts for the per-grade or summary lines — one Text per line. Books can have "
        "~15 grades, so a compact one-Text-per-line list is required.\n\n"
        "Pattern for ONE tappable watchlist comic (two components; adapt ids/values per comic):\n"
        '  {"id":"b_amazing-fantasy-15","component":"Button","variant":"borderless",'
        '"child":"t_amazing-fantasy-15","action":{"event":{"name":"view_book:amazing-fantasy-15"}}},\n'
        '  {"id":"t_amazing-fantasy-15","component":"Text","text":"Amazing Fantasy #15 — CGC 9.0 — last $1,200"}\n\n'
        "CRITICAL: You MUST emit TWO separate A2UI JSON blocks in order:\n"
        "1. First block: a 'createSurface' message:\n"
        '   {"version":"v0.9","createSurface":{"surfaceId":"comic_surface",'
        '"catalogId":"https://a2ui.org/specification/v0_9/basic_catalog.json"}}\n'
        "2. Second block: an 'updateComponents' message with surfaceId 'comic_surface'.\n"
        "Never skip the createSurface block — the client cannot render without it."
    ),
    ui_description=(
        "Dense, data-first, no decorative elements. Build views from a single Column of simple "
        "components (mostly Text); avoid Row/Card/nesting so renders stay small. WATCHLIST: a "
        "Column of borderless Button rows, one per comic, each Button's child a single Text "
        "(title+issue — grade — last price). DETAIL: a ← Watchlist back button first, then a "
        "title Text, a few summary Text lines, and one Text line per grade under \"Median Graded "
        "Sales\"."
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
    tools=[get_watchlist, upsert_comic, remove_comic, add_sale, get_price_history],
    # gemini-2.5-flash's thinking mode intermittently returns an EMPTY completion
    # (0 output tokens, finish=STOP) on the function-calling + large-A2UI-schema path,
    # which makes the agent silently render nothing (~25% of the time). Disabling
    # thinking makes output reliable — this is a structured formatting task that does
    # not benefit from it. Measured: thinking on = 6/8 success; thinking off = 8/8.
    generate_content_config=types.GenerateContentConfig(
        thinking_config=types.ThinkingConfig(thinking_budget=0),
    ),
)

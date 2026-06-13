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
        "  • NON-EMPTY watchlist: a single Column whose children are one WatchlistRow per comic "
        "(id \"r_<book_id>\"). Each WatchlistRow is a custom, self-contained, TAPPABLE row — do NOT "
        "wrap it in a Button and do NOT add separate Text children. Its fields: \"bookId\":"
        "\"<book_id>\" (the REAL id from get_watchlist, e.g. \"amazing-fantasy-15\" — it dispatches "
        "\"view_book:<bookId>\" on tap), \"title\":\"<title> <issue>\" (e.g. \"Amazing Fantasy #15\"), "
        "\"subtitle\":\"<grade/grader, or Raw>\" (e.g. \"CGC 9.0\" or \"Raw\"), and \"price\":"
        "\"$<last_price>\" (preformatted, e.g. \"$1,200\"). The Column's children are ONLY the "
        "WatchlistRow ids (r_<book_id>). One WatchlistRow per comic; tapping one opens its detail.\n"
        "- DETAIL view (request \"show price history and details for book_id X\"): call "
        "get_price_history(book_id=X), then render top-to-bottom: (1) a BACK affordance FIRST — a "
        "Button \"variant\":\"borderless\" whose child is a Text \"← Watchlist\" and whose "
        "action is {\"event\":{\"name\":\"view_watchlist\"}}; (2) a Text with the comic title+issue; "
        "(3) a compact price summary as a FEW single Text lines (e.g. \"Last $935.76\", "
        "\"Median $400.50\", \"Range $57–$2,495\", \"Change +168.1%\"); (4) a Text title "
        "\"Median Graded Sales\", then ONE Text line PER GRADE formatted "
        "\"<grade>   $<median>   (range $<min>–$<max>)\" e.g. \"9.6   $2,150   (range $936–$2,495)\" "
        "— do NOT repeat the word \"Median\"; (5) one Text line for the raw bucket.\n\n"
        "LAYOUT RULES: For the WATCHLIST, use one WatchlistRow per comic (above). For the DETAIL "
        "view, keep using single Text components in a Column for now (richer custom detail widgets "
        "are coming) — one Text per summary line and one Text per grade. Payload size is no longer "
        "tightly capped (the app uses non-streaming message/send), but keep renders clean: prefer "
        "the custom widget for the watchlist and avoid unnecessary nesting elsewhere.\n\n"
        "Pattern for ONE watchlist comic (ONE self-contained component; adapt ids/values per comic):\n"
        '  {"id":"r_amazing-fantasy-15","component":"WatchlistRow","bookId":"amazing-fantasy-15",'
        '"title":"Amazing Fantasy #15","subtitle":"CGC 9.0","price":"$1,200"}\n\n'
        "CRITICAL: You MUST emit TWO separate A2UI JSON blocks in order:\n"
        "1. First block: a 'createSurface' message:\n"
        '   {"version":"v0.9","createSurface":{"surfaceId":"comic_surface",'
        '"catalogId":"com.comicsales.catalog.v1"}}\n'
        "2. Second block: an 'updateComponents' message with surfaceId 'comic_surface'.\n"
        "Never skip the createSurface block — the client cannot render without it."
    ),
    ui_description=(
        "Dense, data-first, no decorative elements. WATCHLIST: a Column of WatchlistRow "
        "components, one per comic (bookId, title, subtitle=grade/Raw, price). DETAIL: a "
        "← Watchlist back button first, then a title Text, a few summary Text lines, and one "
        "Text line per grade under \"Median Graded Sales\". The agent BINDS DATA into the custom "
        "WatchlistRow; the widget owns its look."
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

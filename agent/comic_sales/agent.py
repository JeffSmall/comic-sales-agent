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
        "- DETAIL view (request \"show price history and details for book_id X\", optionally "
        "\"... for the last N days\" or \"... for all available history\"): pick the WINDOW — "
        "N=30/60/90 from \"for the last N days\"; \"all available history\" ⇒ 3650; otherwise the "
        "DEFAULT is 90. Call get_price_history(book_id=X, days=<window>). The SELECTED toggle label "
        "is \"30\"/\"60\"/\"90\" for those, or \"ALL\" for all-history, default \"90\". Then render "
        "to comic_surface a Column \"root\" with these children IN ORDER, using the CUSTOM WIDGETS "
        "below (bind values from the tool result; format money like \"$1,199\", percents \"+29.2%\"):\n"
        "  (1) BACK affordance FIRST — a NavLink {\"label\":\"← Watchlist\",\"action\":"
        "\"view_watchlist\"} (self-contained; do NOT use a Button here).\n"
        "  (2) a Text (variant \"h4\") with the comic title+issue.\n"
        "  (3) a MetricCard \"variant\":\"hero\": label \"Fair Market Value\", value "
        "\"$<summary.median>\", delta \"<sign><summary.change_pct>%\" (FMV ≡ median).\n"
        "  (4) a MetricCluster with metrics = [ {\"label\":\"Last\",\"value\":\"$<summary.last_price>\"}, "
        "{\"label\":\"Median\",\"value\":\"$<summary.median>\"}, "
        "{\"label\":\"Range\",\"value\":\"$<summary.min>–$<summary.max>\"} ].\n"
        "  (5) a Text (variant \"h5\") \"Price Trend\", then a WindowToggle "
        "{\"bookId\":\"X\",\"selected\":\"<the SELECTED label>\"}, then a TrendChart "
        "{\"points\":{\"path\":\"/trend\"},\"days\":<N>} where points is a DATA BINDING (provide the "
        "series via updateDataModel) and N is the window in days (30/60/90; for ALL use 90).\n"
        "  (6) a Text (variant \"h5\") \"Sales by Grade\", then a GradeTierMatrix whose \"grades\" "
        "is ONE entry per by_grade item (highest grade first) "
        "{\"grade\":\"<grade>\",\"count\":<count>,\"median\":\"$<median>\","
        "\"range\":\"$<min>–$<max>\"}, and — if the tool's \"raw\" is present — a final entry "
        "{\"grade\":\"Raw\",\"count\":<raw.count>,\"median\":\"$<raw.median>\","
        "\"range\":\"$<raw.min>–$<raw.max>\"}. \"count\" is a NUMBER, not a string.\n"
        "  (7) a Text (variant \"h5\") \"Grade Variance\", then ONE GradeVarianceRow per grade for "
        "the UP-TO-4 grades with the MOST sales (each needs ≥3 sales; skip Raw). For each, group "
        "that grade's sales (from sales[]) in date order: {\"grade\":\"<grade>\","
        "\"median\":\"$<that grade's median>\",\"demand\":\"<HIGH if its last price >5% above its "
        "first, LOW if >5% below, else MED>\",\"points\":{\"path\":\"/g_<grade with . as _>\"}} "
        "(e.g. grade 9.6 ⇒ path \"/g_9_6\"). Provide each grade's series via its own updateDataModel "
        "block (below). If no grade has ≥3 sales, omit this section (the title and the rows).\n"
        "  (8) a Text (variant \"h5\") \"Recent Sales\", then a CompsTable whose \"rows\" is the "
        "~6 MOST RECENT sales (the LAST entries of the returned sales[] array, NEWEST FIRST): "
        "{\"date\":\"<short date e.g. May 12>\",\"meta\":\"<source> · <grade or 'Raw'>\","
        "\"price\":\"$<price>\"}.\n"
        "Copy numbers from the tool result EXACTLY — never invent or round sales you weren't given.\n\n"
        "CUSTOM WIDGETS (this catalog adds these to the basic Text/Column/Button/Row; emit them "
        "as components with the fields shown — the app styles them):\n"
        "  • WatchlistRow: {bookId, title, subtitle?, price, change?} — a tappable watchlist row.\n"
        "  • NavLink: {label, action} — a self-contained tappable link (e.g. the back affordance).\n"
        "  • MetricCard: {label, value, delta?, variant?(\"hero\"|\"metric\")} — one number.\n"
        "  • MetricCluster: {metrics:[{label,value,delta?}]} — a row of compact metrics.\n"
        "  • TrendChart: {points:{\"path\":\"/trend\"}, days:N} — price line w/ axes; points is a binding.\n"
        "  • WindowToggle: {bookId, selected} — 30/60/90/ALL time-window selector for the trend.\n"
        "  • GradeTierMatrix: {grades:[{grade,count(number),median,range?}]} — grade×volume grid.\n"
        "  • GradeVarianceRow: {grade, median, demand(\"HIGH\"|\"MED\"|\"LOW\"), points:{\"path\":…}} "
        "— one grade's trend + demand; points binds that grade's series.\n"
        "  • CompsTable: {rows:[{date,meta,price}]} — recent transactions.\n\n"
        "Pattern for ONE watchlist comic (ONE self-contained component; adapt ids/values per comic):\n"
        '  {"id":"r_amazing-fantasy-15","component":"WatchlistRow","bookId":"amazing-fantasy-15",'
        '"title":"Amazing Fantasy #15","subtitle":"CGC 9.0","price":"$1,200"}\n'
        "Pattern for a DETAIL (abbreviated — adapt ids/values; root.children lists every child id):\n"
        '  {"id":"root","component":"Column","children":["back","title","fmv","cluster","trend_h",'
        '"window","trend","grades_h","matrix","var_h","var_9_6","comps_h","comps"]},\n'
        '  {"id":"back","component":"NavLink","label":"← Watchlist","action":"view_watchlist"},\n'
        '  {"id":"fmv","component":"MetricCard","variant":"hero","label":"Fair Market Value",'
        '"value":"$1,199","delta":"+29.2%"},\n'
        '  {"id":"cluster","component":"MetricCluster","metrics":[{"label":"Last","value":"$969"},'
        '{"label":"Median","value":"$1,199"},{"label":"Range","value":"$21–$6,500"}]},\n'
        '  {"id":"window","component":"WindowToggle","bookId":"amazing-spider-man-129","selected":"90"},\n'
        '  {"id":"trend","component":"TrendChart","points":{"path":"/trend"},"days":90},\n'
        '  {"id":"matrix","component":"GradeTierMatrix","grades":[{"grade":"9.6","count":4,'
        '"median":"$6,155","range":"$5,811–$6,500"},{"grade":"Raw","count":12,"median":"$95"}]},\n'
        '  {"id":"var_9_6","component":"GradeVarianceRow","grade":"9.6","median":"$6,155",'
        '"demand":"HIGH","points":{"path":"/g_9_6"}},\n'
        '  {"id":"comps","component":"CompsTable","rows":[{"date":"May 12","meta":"eBay · CGC 9.4",'
        '"price":"$4,650"}]}\n\n'
        "CRITICAL: emit these A2UI JSON blocks, each in its OWN <a2ui-json>…</a2ui-json>, IN ORDER:\n"
        "1. createSurface: "
        '{"version":"v0.9","createSurface":{"surfaceId":"comic_surface",'
        '"catalogId":"com.comicsales.catalog.v1"}} — never skip it; the client cannot render '
        "without it.\n"
        "2. (DETAIL ONLY) one updateDataModel block PER bound series — emit BEFORE updateComponents "
        "so the bindings resolve. Prices are PLAIN NUMBERS (no $, no commas), OLDEST FIRST, copied "
        "EXACTLY from the tool result, in order:\n"
        '   • the overall trend: {"version":"v0.9","updateDataModel":{"surfaceId":"comic_surface",'
        '"path":"/trend","value":[57.0,75.5,120.0, …]}} (every sales[] price).\n'
        '   • one per GradeVarianceRow grade: {"version":"v0.9","updateDataModel":{"surfaceId":'
        '"comic_surface","path":"/g_<grade>","value":[ …that grade\'s prices, oldest first ]}} '
        '(path matches the row\'s points.path, e.g. "/g_9_6").\n'
        "3. updateComponents with surfaceId 'comic_surface' (the component tree above).\n"
        "The WATCHLIST view emits only blocks 1 and 3 (no data model)."
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

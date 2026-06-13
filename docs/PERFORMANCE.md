# Performance — tap→render latency (measured 2026-06-13)

> **TL;DR.** A book-detail tap takes **~12.4 s** end-to-end, running locally on a laptop.
> **82–90 % of that is the second Gemini call (the render), and it's bound by OUTPUT-token
> generation (~240 tok/s)** — the model hand-emits ~2,600 tokens of component JSON *plus the
> literal numeric price arrays*. Nothing in the Flutter app, the network, or Firestore is the
> problem (all <1 s combined; app/network < 100 ms). The fix is to **emit fewer output tokens**
> and/or **skip the LLM for deterministic taps** — not to optimize the render path.

## How it was measured

- **Agent side:** temporary ADK `before/after` callbacks (agent / model / tool) recording
  `time.perf_counter()` durations and `LlmResponse.usage_metadata` token counts. (Reverted after
  the run — see the git history around this date if you need to re-add them.)
- **Driver:** direct A2A `message/send` curls against the local `adk api_server` (each curl is a
  **fresh context**, so these are *best-case* — the real app threads `contextId`, so session
  history accumulates and input grows over a session).
- **Env:** local laptop → Gemini API + Firestore `nam5`; `gemini-2.5-flash`, `thinking_budget=0`.
- App-side parse/inject was confirmed negligible: `curl total` tracked `total_agent` to within
  ~60 ms (localhost), so everything outside the agent turn is <1 % of the round trip.

## The numbers (ms)

Per tap the agent runs a two-call function-calling loop: **model #1** decides which tool to call,
the **tool** runs, **model #2** renders the A2UI.

| Stage | Detail — ASM #129 | Watchlist (back) | Detail — Batman #227 |
|---|--:|--:|--:|
| model #1 — tool decision | 944 (out 33 tok) | 940 (out 10) | 1023 (out 30) |
| Firestore tool | 1187 *(cold)* | 1346 | **163** *(warm)* |
| **model #2 — render** | **10264** (out **2526** tok) | 4028 (out 885) | **11186** (out **2658** tok) |
| **total agent turn** | 12429 | 6348 | 12404 |
| curl total (+network) | 12486 | 6358 | 12416 |

Input token counts: model #1 prompt ≈ **14.5K** tokens (the A2UI system prompt; ~40K chars of
schema scaffolding alone), model #2 prompt ≈ **22K** (adds the tool result — the ~65 sales as JSON).

## What the data proves

1. **The render call (model #2) is the bottleneck (82–90 % of a detail tap), and it's
   OUTPUT-bound.** Gemini decodes at a steady **~240 tok/s** here (2526/10.3 s, 2658/11.2 s,
   885/4.0 s all land there), so **latency ≈ output_tokens ÷ 240**. A detail screen emits ~2,600
   tokens; the watchlist emits ~885 → ~4 s. Output *size* is the latency.
2. **Prefill / caching is NOT the main lever.** `cached_tok ≈ 14,000` on the repeat turns shows
   Gemini's **implicit context cache already covers ~14K of the ~22K input tokens**. Caching the
   rest wouldn't touch the 10 s of output decoding.
3. **model #1 is ~1 s of pure overhead per tap** — it emits a 10–33-token function call just to
   decide "call `get_price_history`." A tap's intent is already known (`view_book:<id>`), so this
   round trip is avoidable for navigation.
4. **Firestore is secondary:** ~1.2 s cold (first query of a session, connection setup), **~0.16 s
   warm**. It amortizes.
5. **Not the problem (confirmed):** network (~60 ms localhost), the app's regex/tolerant-JSON
   parse, GenUI widget build, scroll animation — bounded <100 ms by the curl-vs-agent gap.
6. **Amplifier:** non-streaming `message/send` blocks for the *entire* turn, so the user sees only a
   spinner for the full ~12 s — zero progressive feedback. And `contextId` threading means input
   tokens (and prefill cost) grow as a session goes on, so the live app is *worse* than these
   fresh-context numbers.

## Levers, in priority order

1. **Stop sending the price arrays through the LLM (biggest win).** Have `get_price_history` / the
   app populate the chart data model (`/trend`, `/g_*`) directly; the render call then emits only
   structural component JSON. Cutting ~1,500 of the ~2,600 output tokens ≈ **halves** detail
   latency. (The data-model binding plumbing already exists — today the model still transcribes the
   numbers into `updateDataModel.value`; the goal is to remove that transcription.)
2. **Skip the LLM for deterministic taps.** Tapping a row or the window toggle has a fully-
   determined outcome — render the detail from a Dart/template path off the tool result, and reserve
   the model for genuine natural-language turns. That removes **both** model calls
   (~12 s → ~0.2 s warm tool fetch). This is the largest possible win but the biggest architectural
   change (moves rendering authority from agent→app for the deterministic paths).
3. **Restore streaming / progressive feedback.** Even keeping the LLM, a streamed or staged/skeleton
   render removes the dead-spinner feel. (Streaming was dropped to fix the old ~9 KB SSE truncation —
   any return to it must not reintroduce that; see `app/CLAUDE.md` → Transport.)
4. **Minor:** trim the system prompt; warm Firestore on launch (cold ~1.2 s → warm ~0.16 s); watch
   session-history growth from `contextId` threading.

> **Tension to weigh:** levers 1–2 move work off the LLM and toward deterministic app/tool code,
> which trades some of the "the agent decides what to show" generality for speed. For the
> *deterministic* navigation paths (tap row, toggle window) that trade is almost free — the outcome
> was never really a model decision. Keep the LLM for actual natural-language requests.

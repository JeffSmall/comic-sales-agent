# ADR-008 — Positioning in the generative-UI landscape

**Status:** Accepted
**Date:** 2026-06-10
**Related:** CPCD §6 (catalog = Tufte doctrine), CPCD §7 (ADR log), ADR-002 (GenUI ↔ A2UI ↔ ADK),
ADR-006 (isolate GenUI behind an adapter), root `CLAUDE.md` key invariants.

---

## Context

"Generative UI" is an overloaded term. It's useful to think of it as a single spectrum —
**who owns the UI vocabulary, and how much is the model allowed to invent?** — rather than
discrete categories:

```
client owns fixed slots   →   agent composes from a catalog   →   model generates the app
  (1) static / curated          (2) declarative JSON tree            (3) true generative
```

The trade-off is constant: **flexibility and novelty** (rightward) versus **safety,
consistency, native feel, and cross-surface portability** (leftward).

Representative camps:

| Flavor | Who owns the UI vocabulary | Representative of |
|--------|----------------------------|-------------------|
| 1 — static / curated | the client / host app | **Apple** (App Intents + SwiftUI), AG-UI / CopilotKit |
| 2 — declarative JSON | the **agent composes** from a fixed catalog | **This project + Google** (A2UI / Flutter GenUI); Vercel AI SDK leans 2→3 |
| 3 — true generative | the **model** (arbitrary HTML/JS/app) | Anthropic & OpenAI "MCP apps" / artifacts / Apps SDK |

The boundaries are fuzzy (AG-UI can stream "generative" snippets; Vercel's RSC approach blurs
2 and 3). Treat it as a spectrum.

We need to state, on the record, where this product deliberately sits and why — so the choice
is not silently re-litigated every time a richer UI need appears.

## Decision

**We position the comic sales agent squarely in flavor 2 (declarative, agent-composed UI), and
we deliberately fence it toward flavor 1's safety. We explicitly reject flavor 3 for the
agent-emitted UI path.**

Concretely, this is already encoded as a hard invariant (root `CLAUDE.md`):

> The agent never sends raw HTML or styled text. It sends **catalog payloads only**.

- The agent emits **A2UI** — a declarative JSON component tree (`createSurface` +
  `updateComponents`) — and the Flutter **GenUI** client renders it into native Material
  widgets. The agent *composes layout* (flavor 2), but may only use widgets the client has
  registered (flavor 1's safety).
- The UI vocabulary is a **fixed, versioned catalog** (`shared/catalog/`): today
  `BasicCatalog`; the Phase 3 roadmap adds `Sparkline`, `GradeTierMatrix`,
  `SmallMultiplesGrid`, etc.
- When the model needs richer output, **we extend the catalog vocabulary** — we do not open the
  door to arbitrary, model-generated code/markup.

## Rationale

- **The domain rewards consistency over novelty.** This is a data-dense collectibles/finance
  tracker built on a Tufte doctrine (CPCD §6): high data-ink, monochrome with a single accent,
  right-aligned numerics, sparklines, dense matrices. We want the *same* trustworthy, native,
  high-data-ink rendering every time — not a freshly hand-written chart per query.
- **Safety and trust.** A constrained catalog means the agent cannot emit unsafe or
  off-brand UI. The client only renders primitives it already vets and styles.
- **Native performance and cross-surface portability.** A2UI is a framework-agnostic
  *declarative spec*, not code. The same payload renders natively on iOS today and could render
  on other GenUI surfaces later. (This is arguably a *purer* flavor 2 than Vercel's
  "generative UI," which streams actual React/RSC code and therefore blurs into flavor 3.)
- **Alignment with the chosen stack.** ADR-002 already committed us to Google's
  GenUI ↔ A2UI ↔ ADK path; that stack *is* the flavor-2 bet. This ADR makes the worldview
  explicit rather than incidental.

## Consequences

**Positive**
- Predictable, native, on-brand UI; small attack/inconsistency surface.
- Clear extension mechanism: richer needs → new catalog items, reviewed and versioned.
- Portability: the agent's output is a spec, decoupled from any one renderer (reinforces ADR-006).

**Negative / accepted limits**
- The model **cannot** invent genuinely novel interactions or one-off bespoke layouts the
  catalog doesn't cover. Every new UI capability is a deliberate engineering step (build the
  widget, register it, version the contract), not an emergent model behavior.
- We forgo the "wow" flexibility of flavor-3 MCP-style apps. If a future use case genuinely
  needs arbitrary model-authored surfaces (e.g. an exploratory analytics sandbox), that would be
  a **new decision** superseding this one — not an incremental tweak.

## Where the big players sit (for reference)

- **Google — flavor 2.** This project *is* Google's bet: ADK + A2A (interop transport) + A2UI +
  Flutter GenUI. "Generative UI as a protocol": declarative, catalog-constrained, native,
  cross-device.
- **Apple — flavor 1.** Apple Intelligence / Siri orchestrates results *into the app's own
  pre-built SwiftUI* via **App Intents**; the model is a router into curated native components,
  not a UI author. Consistent with their on-device / privacy / native-control priorities and a
  temperamental rejection of flavor 3.
- **Anthropic & OpenAI — flavor 3.** MCP "apps" / MCP-UI, Claude artifacts/apps, OpenAI Apps
  SDK: the model ships an actual interactive surface (HTML/JS/iframe). Maximum flexibility, at
  the cost of the safety/consistency/native properties the other camps optimize for.

> Note: this mapping reflects the landscape as understood at authoring time (assistant knowledge
> cutoff Jan 2026); it is not sourced from a specific I/O / WWDC keynote. Re-validate against the
> latest announcements before quoting it externally.

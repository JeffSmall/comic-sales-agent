# Vertex AI / GCP conventions

No Vertex AI Agent Engine usage established yet — the agent runs on Google ADK with
direct Gemini API access (not Vertex AI Agent Engine).

## GCP project

Project: `comic-sales-agent`
Region/Firestore: `nam5`
Auth: Application Default Credentials (`gcloud auth application-default login`)

## Model

Use `gemini-2.5-flash`. Never use `gemini-2.0-flash` (decommissioned, returns 404).
See `.claude/rules/adk.md` for thinking_budget and generate_content_config requirements.

## Phase 4 note

Cloud Run deploy is deferred (Phase 4). When it lands, note that the eBay scraper
cannot run on Cloud Run (datacenter IP blocked by Imperva) — the scraper stays local.

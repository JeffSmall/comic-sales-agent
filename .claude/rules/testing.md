# Testing conventions

No formal test conventions established yet for this project.

Key constraints for any tests added:
- Network calls (eBay scraper, Firestore, Gemini API) require the sandbox disabled.
- The eBay scraper must run from a residential IP — datacenter IPs are blocked by Imperva.
- Firestore integration tests use the real `comic-sales-agent` GCP project with ADC auth;
  do not mock Firestore (divergence between mocks and real schema has caused silent failures).

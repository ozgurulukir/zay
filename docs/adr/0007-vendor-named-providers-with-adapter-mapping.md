# Vendor-named providers with internal adapter mapping

Nova's `provider` value in user-facing config and env is a vendor/runtime name (`openai`, `openai_compatible`, `ollama`, `llama.cpp`, `openrouter`, future `anthropic`, …) — *not* a `LanguageModel` adapter variant name. A small static table maps each provider to its adapter (`codex_responses` / `openai_responses` / `openai_compatible`), default `base_url`, and auth requirement. This keeps user-facing names aligned with how users think about their model source while letting Nova reorganise its adapters freely; `OPENAI_MODEL=<provider>/<model>` parses strictly against the provider table, and unknown or not-yet-implemented providers (e.g. `anthropic`) produce a soft-fail thread message rather than a startup crash.

## Considered Options

- Use adapter names as the user-facing `provider` (rejected — exposes implementation detail; `openai_codex` is meaningless to a user who just wants "OpenAI").
- A single generic `openai_compatible` provider for everything non-Codex with `base_url` carrying the vendor distinction (rejected — loses the chance to ship sensible base_url defaults per vendor and a richer picker later).
- Imply the provider from env-var presence (`OPENAI_BASE_URL` set → openai_compatible) (rejected — the "magic" behaviour we were already trying to remove).

## Consequences

The provider table is the extension point for future model sources; adding a vendor is a one-row change plus, eventually, a picker entry. `openai_compatible` doubles as a user-facing provider name (the BYO-base_url escape hatch) and the internal adapter name — same string, two roles, accepted as a small naming coincidence rather than disambiguated. User-defined providers (future work) will extend the same table.

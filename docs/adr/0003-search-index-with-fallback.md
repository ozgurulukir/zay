# Search index with fallback

`search_codebase` uses a long-lived FFF search index as its fast path, warmed in the background when Nova starts, but falls back to shell commands while the index is not ready or if FFF becomes unavailable for the session. This keeps the agent responsive and preserves a reliable search capability at startup or after FFF failure, accepting that fallback results are slower, unranked, and not cursor-paginated.

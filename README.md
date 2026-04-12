# Frank Investigator

Frank Investigator is a Rails 8.1 news fact-checking pipeline that assesses claims extracted from news articles through evidence graphs, source authority analysis, and multi-model LLM consensus.

Submit a public article URL. Frank Investigator normalizes it, fetches the page with headless Chromium, extracts canonical claims, follows in-body citations, retrieves corroborating evidence, and produces a structured verdict for each claim with full provenance.

## Core Principle: Truth Over Consensus

A fact does not become false because a million sources repeat a falsehood, and a falsehood does not become true because it is popular.

- Authority trumps volume. A single primary source outweighs any number of secondary sources.
- Primary source veto. If a primary source disputes a claim, confidence is capped.
- LLM votes are weighted by confidence, not counted by heads.
- Independence matters more than quantity. Ten articles from the same wire service count as one voice.
- Smear and viral campaign defense. Unsubstantiated viral claims are capped at low confidence.
- Evaluative thesis claims are treated conservatively. Broad judgments like "X was a good minister" must decompose into measurable subclaims before they can earn strong support.
- Circular citation detection. Echo chambers where outlets only cite each other are penalized.
- Headline bait detection. Articles with sensational headlines that hedge in the body are discounted.
- Rhetorical fallacy analysis. Bait-and-pivot, appeal to authority, strawman, and other fallacies are detected and flagged.

## What It Does

- Fetches articles via headless Chromium with stealth hardening and adaptive timeouts
- Extracts main content with noise filtering (ads, sidebars, comment sections, trending lists)
- Handles PDF, DOCX, XLSX, and CSV document evidence
- Extracts and deduplicates claims using fingerprint, semantic key, and similarity matching
- Classifies source authority (primary/secondary/low) and source role (government, legal, statistics, oversight, research, reporting, opinion, editorial, blog amplification)
- Detects editorial independence groups to prevent volume-based manipulation
- Follows in-body links up to configurable depth, building an evidence graph
- Assesses claims via multi-model LLM consensus with graduated disagreement penalties
- Tracks claim variants and mutations across articles
- Detects source corrections and flags stale assessments
- Provides full verdict history with evidence provenance snapshots
- Analyzes headline-body divergence and headline citation amplification
- Detects 16 rhetorical fallacies including 6 derived from Schopenhauer's 38 Stratagems (19 of 38 covered)
- Detects source misrepresentation: when an article claims a source says X but it actually says Y
- Detects temporal manipulation: old data presented as current, selective timeframes, timeline mixing
- Detects statistical deception: cherry-picked baselines, misleading percentages, missing denominators
- Detects selective quotation: quotes truncated or taken out of context to reverse meaning
- Detects authority laundering: citation chains that inflate low-authority sources into apparent credibility
- Analyzes contextual gaps: what the article omits that would change the reader's conclusion
- Searches for counter-evidence addressing each identified gap
- Detects coordinated narrative campaigns: finds related coverage, compares narrative fingerprints, flags convergent framing and convergent omissions across outlets
- Links related investigations more aggressively when the same subject is covered through opposed policy or fiscal framing
- Uses hybrid related-investigation retrieval: sqlite-vec embeddings retrieve candidates, then subject/topic guardrails decide what is truly related
- Scores emotional manipulation: emotional temperature vs evidence density, calibrated so passionate journalism backed by evidence is not penalized
- Generates an executive summary from 15 pipeline steps with calibrated scoring that distinguishes normal editorial imperfections from deliberate manipulation
- Live updates via Turbo Streams as the pipeline progresses

## Stack

- Ruby 4.0.1 / Rails 8.1
- SQLite3 (WAL mode, tuned pragmas)
- Solid Queue (background jobs), Solid Cable (WebSockets), Solid Cache
- Headless Chromium (page fetching)
- OpenRouter (multi-model LLM consensus via RubyLLM)
- Propshaft, Importmap, Turbo, Stimulus
- Server-rendered UI, no JavaScript frameworks

## Getting Started

```bash
bin/setup          # Install deps, create DB, run migrations
bin/dev            # Start Rails + Solid Queue via Procfile.dev
```

Required environment variables:

```bash
OPENROUTER_API_KEY=your_key_here           # Required when FRANK_INVESTIGATOR_LLM_PROVIDER=openrouter
OPENAI_API_KEY=your_key_here               # Required when FRANK_INVESTIGATOR_LLM_PROVIDER=openai, and for direct OpenAI embeddings
```

Optional configuration:

```bash
FRANK_INVESTIGATOR_LOCALE=pt-BR            # en or pt-BR (default: pt-BR)
FRANK_INVESTIGATOR_MAX_LINK_DEPTH=1        # How deep to follow links (default: 1)
FRANK_INVESTIGATOR_ARTICLE_FRESHNESS_TTL=3600  # Cache TTL in seconds (default: 3600)
FRANK_INVESTIGATOR_LLM_PROVIDER=openrouter      # or openai
FRANK_INVESTIGATOR_LLM_MODELS=openai/gpt-5-mini,anthropic/claude-sonnet-4-6,google/gemini-2.5-pro
FRANK_INVESTIGATOR_VECTOR_SEARCH_ENABLED=true
FRANK_INVESTIGATOR_EMBEDDING_PROVIDER=openrouter   # or openai
FRANK_INVESTIGATOR_EMBEDDING_MODEL=openai/text-embedding-3-small   # use text-embedding-3-small with provider=openai
FRANK_INVESTIGATOR_EMBEDDING_DIMENSIONS=1536
QUARANTINED_MODELS=                        # Comma-separated models to skip
```

## Testing

```bash
bundle exec rails test                    # Full suite
bundle exec rails test test/path_test.rb  # Single file
```

## Deployment (Kamal)

The app deploys via [Kamal](https://kamal-deploy.org/) to any server with Docker and SSH access.

### First-time setup

Export these environment variables in your shell before deploying. Kamal reads them via `.kamal/secrets` — no manual editing of secret files needed.

```bash
export KAMAL_REGISTRY_USERNAME=your-github-username
export KAMAL_REGISTRY_PASSWORD=ghp_your_github_pat    # PAT with write:packages scope
export OPENAI_API_KEY=sk-proj-...
export FRANK_INVESTIGATOR_LLM_PROVIDER=openai
export FRANK_INVESTIGATOR_LLM_MODELS=gpt-5-mini
export FRANK_AUTH_SECRET=$(openssl rand -hex 32)
export JOBS_AUTH_PASSWORD=$(openssl rand -hex 16)
export GOOGLE_ANALYTICS_ID=G-XXXXXXXXXX               # Optional
```

Secret hygiene:

- Never commit `.kamal/secrets`, `.kamal/secrets.<destination>`, `.kamal/secrets-common`, `config/deploy.env`, or `config/master.key`.
- The repo only tracks example files such as `.kamal/secrets.example` and `config/deploy.env.example`.
- Keep real runtime secrets in ignored local files or your shell environment, not in tracked YAML, compose files, or docs.

Then bootstrap the server:

```bash
bin/kamal setup
```

Point your DNS (A record) to the server IP for the hostname configured in `config/deploy.yml`.

### Deploy

```bash
bin/kamal deploy
```

After the first deploy that includes vector search, backfill embeddings for existing completed investigations so cross-reference can use the full corpus instead of only newly completed reports:

```bash
bin/kamal app exec -r web --reuse "bin/rails frank:index_embeddings[250]"
```

Repeat that command until it reports no remaining work, or increase the batch size if the server has enough headroom.
If OpenRouter is still failing in production, switch embeddings to `FRANK_INVESTIGATOR_EMBEDDING_PROVIDER=openai` and set `OPENAI_API_KEY` before running the backfill.

### Other commands

```bash
bin/kamal console       # Open Rails console in the web container
bin/kamal shell         # Open bash in the web container
bin/kamal logs          # Tail web logs
bin/kamal worker_shell  # Open bash in the worker container
bin/kamal worker_logs   # Tail worker logs
bin/kamal app details   # Show container status
```

### Maintenance tasks

```bash
bin/rails 'frank:reanalyze[SLUG]'   # Reset analysis-stage steps and rerun analyzers for one investigation
bin/rails 'frank:refresh[SLUG]'     # Rebuild one investigation from stored snapshots and current heuristics
bin/rails 'frank:crossref[SLUG]'    # Recompute related-investigation context for one investigation
bin/rails 'frank:index_embeddings[250]'  # Backfill vector embeddings for completed investigations
bin/rails frank:crossref_all        # Recompute related-investigation context for all completed investigations
```

Use `frank:reanalyze` when analyzer logic changes and you want a report to pick up new heuristics without re-fetching the source article.
Use `frank:refresh` when claim extraction, source-role classification, or parser cleanup changed and the investigation needs a full rebuild from stored article content without manual database edits.

### How it works

- `config/deploy.yml` defines the Kamal service (server, image, volumes, env)
- `.kamal/secrets` pulls secrets from local env vars — no raw credentials in git
- kamal-proxy handles SSL via Let's Encrypt and routes by hostname
- `frank_investigator_storage` Docker volume persists SQLite databases
- Production runs separate `web` and `worker` containers for this app only
- The `web` role serves HTTP traffic and does not embed Solid Queue in Puma
- The `worker` role runs `./bin/jobs start` and is not exposed through kamal-proxy
- The shared worker pool consumes both `default` and `solid_queue_recurring`, so recurring recovery/cleanup jobs are not stranded
- Fetch-heavy jobs run on a dedicated low-concurrency `fetch` queue to limit Chromium pressure
- Chromium is included in the Docker image for headless page fetching
- The app image compiles and loads a vendored `sqlite-vec` extension, then stores investigation embeddings in SQLite for related-investigation retrieval
- If LLM-backed analysis degrades, the heuristic fallback remains conservative: evaluative claims stay `not_checkable` or `needs_more_evidence`, and opinion/blog amplification is downweighted automatically
- Cross-investigation enrichment now uses hybrid retrieval: vector candidates widen recall, while subject/topic guardrails and heuristic fallback keep unrelated investigations out

## Deployment Notes

- `bin/kamal deploy` only touches containers labeled for the `frank-investigator` service.
- This app's proxy configuration only serves `investigator.themakitachronicles.com`.
- Both `web` and `worker` mount the same persistent `/rails/storage` path, so SQLite databases remain outside container lifecycle.
- The shared `/opt/makita/content` bind mount is still passed into both containers at `/content`.

## Legacy Compose Helper

The repo still includes `docker-compose.production.yml` and `bin/deploy` as a legacy non-Kamal path. They mirror the same split runtime:

- `web` serves Rails/Thruster only
- `worker` runs Solid Queue only
- both share the same persistent storage and content mounts

Prefer Kamal for production unless you intentionally need the compose-based path.

## Internationalization

All user-facing text is internationalized via Rails i18n. Currently supported locales:

- **English** (`en`) — default
- **Brazilian Portuguese** (`pt-BR`)

Set `FRANK_INVESTIGATOR_LOCALE` to switch. LLM analysis results (reason summaries, fallacy explanations) are generated in the configured locale while structured fields remain in English for consistency.

## Architecture

- Canonical claims are first-class records, not transient prompt output
- Articles, claims, evidence, and follow-up links form a graph that can be revisited
- Every pipeline step is idempotent
- Service objects are small, isolated, and unit-testable
- The LLM is a planner and synthesizer over evidence, not the only source of truth

## Audience

Brazil-first source profiling and testing for outlets such as UOL, G1, CartaCapital, Revista Oeste, Gazeta do Povo, VEJA, Folha, Estadao, and Agencia Brasil. US and international sources are also supported.

## License

Frank Investigator is licensed under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0).

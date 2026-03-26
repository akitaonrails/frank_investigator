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
- Circular citation detection. Echo chambers where outlets only cite each other are penalized.
- Headline bait detection. Articles with sensational headlines that hedge in the body are discounted.
- Rhetorical fallacy analysis. Bait-and-pivot, appeal to authority, strawman, and other fallacies are detected and flagged.

## What It Does

- Fetches articles via headless Chromium with stealth hardening and adaptive timeouts
- Extracts main content with noise filtering (ads, sidebars, comment sections, trending lists)
- Handles PDF, DOCX, XLSX, and CSV document evidence
- Extracts and deduplicates claims using fingerprint, semantic key, and similarity matching
- Classifies source authority (primary/secondary/low) and source role (government, legal, statistics, oversight, research, news)
- Detects editorial independence groups to prevent volume-based manipulation
- Follows in-body links up to configurable depth, building an evidence graph
- Assesses claims via multi-model LLM consensus with graduated disagreement penalties
- Tracks claim variants and mutations across articles
- Detects source corrections and flags stale assessments
- Provides full verdict history with evidence provenance snapshots
- Analyzes headline-body divergence and headline citation amplification
- Detects rhetorical fallacies that undermine the article's own factual claims
- Detects source misrepresentation: when an article claims a source says X but it actually says Y
- Detects temporal manipulation: old data presented as current, selective timeframes, timeline mixing
- Detects statistical deception: cherry-picked baselines, misleading percentages, missing denominators
- Detects selective quotation: quotes truncated or taken out of context to reverse meaning
- Detects authority laundering: citation chains that inflate low-authority sources into apparent credibility
- Analyzes contextual gaps: what the article omits that would change the reader's conclusion
- Searches for counter-evidence addressing each identified gap
- Detects coordinated narrative campaigns: finds related coverage, compares narrative fingerprints, flags convergent framing and convergent omissions across outlets
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
OPENROUTER_API_KEY=your_key_here           # Required for LLM assessment
```

Optional configuration:

```bash
FRANK_INVESTIGATOR_LOCALE=pt-BR            # en or pt-BR (default: pt-BR)
FRANK_INVESTIGATOR_MAX_LINK_DEPTH=1        # How deep to follow links (default: 1)
FRANK_INVESTIGATOR_ARTICLE_FRESHNESS_TTL=3600  # Cache TTL in seconds (default: 3600)
FRANK_INVESTIGATOR_OPENROUTER_MODELS=openai/gpt-5-mini,anthropic/claude-3.7-sonnet,google/gemini-2.5-pro
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
export OPENROUTER_API_KEY=sk-or-v1-...
export FRANK_INVESTIGATOR_OPENROUTER_MODELS=anthropic/claude-sonnet-4-6,openai/gpt-5.4,google/gemini-3.1-pro-preview
export FRANK_AUTH_SECRET=$(openssl rand -hex 32)
export JOBS_AUTH_PASSWORD=$(openssl rand -hex 16)
export GOOGLE_ANALYTICS_ID=G-XXXXXXXXXX               # Optional
```

Then bootstrap the server:

```bash
kamal setup
```

Point your DNS (A record) to the server IP for the hostname configured in `config/deploy.yml`.

### Deploy

```bash
kamal deploy
```

### Other commands

```bash
kamal console           # Open Rails console
kamal shell             # Open bash in the container
kamal logs              # Tail production logs
kamal app details       # Show container status
```

### How it works

- `config/deploy.yml` defines the Kamal service (server, image, volumes, env)
- `.kamal/secrets` pulls secrets from local env vars — no raw credentials in git
- kamal-proxy handles SSL via Let's Encrypt and routes by hostname
- `frank_investigator_storage` Docker volume persists SQLite databases
- Solid Queue runs inside Puma (`SOLID_QUEUE_IN_PUMA=1`) — single container
- Chromium is included in the Docker image for headless page fetching

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

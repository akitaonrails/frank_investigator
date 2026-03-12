# Frank Investigator — Development Guide

## Project Overview

Frank Investigator is a Rails 8.1 fact-checking pipeline that assesses claims extracted from news articles. It uses SQLite3, Solid Queue, Solid Cable, Solid Cache, Propshaft, and Turbo Streams for live updates.

## Core Principle: Truth Over Consensus

**A fact does not become false because a million sources repeat a falsehood, and a falsehood does not become true because it is popular.**

This is the foundational design constraint of the entire system. Every scoring, weighting, and aggregation decision must respect it:

1. **Authority trumps volume.** A single primary source (government data, court records, scientific papers, official corrections) always outweighs any number of secondary sources (news articles, blogs, social media) that contradict it. The `SECONDARY_WEIGHT_CAP` ensures that sheer volume of non-primary evidence can never dominate.

2. **Primary source veto.** If a primary-tier source disputes a claim and no primary source supports it, the verdict cannot be `:supported` — it is forced to `:mixed` and confidence is capped. Two opposing primary sources also force `:mixed`.

3. **LLM votes are weighted by confidence, not counted by heads.** A single model with high confidence outweighs two models with low confidence. We never use simple majority voting.

4. **Independence matters more than quantity.** Ten articles from the same wire service count as one editorial voice. The `IndependenceAnalyzer` clusters sources by editorial origin and the independence score reflects unique editorial groups, not article count.

5. **Verdicts are living, not permanent.** Assessments go stale and get reassessed when new evidence appears. The `VerdictSnapshot` audit trail tracks every change with the evidence state at that point, so we never lose history.

When in doubt, prefer `needs_more_evidence` over a weakly supported verdict. Conservative assessment protects users better than false confidence.

## Running the App

```bash
bin/setup          # Install deps, create DB, run migrations
bin/dev            # Start Rails + Solid Queue via Procfile.dev
```

## Testing

```bash
bundle exec rails test                    # Full suite
bundle exec rails test test/path_test.rb  # Single file
```

All tests must pass before committing. Current count: 338+.

## Key Architecture Decisions

- **No JavaScript frameworks.** UI is server-rendered with Turbo Streams. No React, no Vue, no Stimulus controllers beyond what Rails provides.
- **Custom CSS only.** Propshaft pipeline, no Tailwind, no Bootstrap. CSS variables in `application.css`.
- **SQLite in production.** WAL mode, tuned pragmas. No Postgres dependency.
- **LLM via OpenRouter.** Multi-model consensus through `RubyLLM` gem. Models configurable via `OPENROUTER_MODELS` env var.
- **Background jobs via Solid Queue.** Recurring jobs in `config/recurring.yml`.

## Code Conventions

- Services live in `app/services/` organized by domain (`analyzers/`, `fetchers/`, `llm/`, `parsing/`, `articles/`).
- Services use `.call` class method pattern delegating to `#call` instance method.
- Models use Rails enums with string backing and prefix option.
- Tests use Minitest, not RSpec. No mocking of database — integration tests hit real SQLite.

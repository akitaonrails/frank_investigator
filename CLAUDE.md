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

6. **Smear/viral campaign defense.** When 3+ secondary sources support a claim but zero primary sources exist, the system flags this as "unsubstantiated viral" and caps confidence at 0.45. Volume of gossip without original evidence (no confession, no court verdict, no official record) must never produce a high-confidence `:supported` verdict.

7. **Circular citation detection.** Articles that only cite each other (A→B, B→A) or cite sources with no substantive content are flagged as thin citation chains. The `CircularCitationDetector` walks `ArticleLink` relationships to identify echo chambers where outlets reference each other but none have original evidence. Citation depth score penalizes these patterns.

8. **Citation grounding required.** An article is only "grounded" if it links to substantive external sources outside the evidence set. Articles with no outbound citations or that only cite other articles in the same evidence set are treated as ungrounded, reducing the overall citation depth score.

9. **Headline-body divergence penalty.** Articles whose headlines make definitive claims ("accused of", "caught", "confirmed") while their body text hedges ("allegedly", "no police report filed", "sources say", "could not be verified") have their authority score discounted. A baiting article is unreliable evidence regardless of the outlet's general reputation.

10. **Headline citation amplification detection.** When Article B quotes Article A's sensational headline but not its qualifying body content, this is flagged as "headline amplification". This is a key mechanism in smear campaigns: one outlet writes a baiting headline, others cite it as established fact. The `HeadlineCitationDetector` catches this pattern and penalizes the evidence set's citation depth score.

11. **Rhetorical fallacy detection.** After claims are assessed, the `RhetoricalFallacyAnalyzer` examines the article's written structure against its own factual claims. It detects 14 fallacy types including classical fallacies and four patterns derived from Schopenhauer's 38 Stratagems ("The Art of Being Right", 1831): equivocation (#2 — same term, different meanings), odious categorization (#32 — dismissive labels to discredit opposition), twisted conclusion (#9 — data supports X, article concludes Y), and paradox framing (#13 — making dissent seem absurd). When an article's rhetoric undermines its own high-confidence factual claims, this is flagged with severity and the specific undermined claim is identified.

12. **Contextual gap detection.** An article can be factually correct in every individual claim and still be manipulative through omission. The `ContextualGapAnalyzer` identifies what the article chooses not to say: scope mismatches (citing foreign studies for local conclusions), missing counter-evidence, theoretical-vs-practical gaps, distributional blindness, historical amnesia, reversal framing (presenting partial rollbacks as new benefits), benefit pass-through gaps (assuming policy benefits reach consumers without evidence), and selective attribution (crediting actors for outcomes they didn't cause). It then searches the web for evidence addressing each gap. An article with all claims "supported" but major contextual gaps cannot receive a "strong" quality rating.

13. **Completeness over accuracy.** Factual accuracy alone does not make an article trustworthy. An article that assembles true facts into a misleading narrative by omitting critical context is the most dangerous kind of misinformation because it passes every individual fact-check. The contextual completeness score penalizes this pattern.

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

All tests must pass before committing. Current count: 678+.

### LLM stubbing in tests

Tests use WebMock (`test/support/llm_stubs.rb`) to stub OpenRouter API calls. This makes the suite run in ~1.5s instead of ~9 minutes. The stubs return schema-aware responses based on the request's schema name.

**When adding or modifying stubs:**

- Every stubbed response MUST resemble a real LLM response. Before writing a stub, make at least one live call to see the actual response shape, field names, and realistic values. Do not invent response structures — base them on observed LLM output.
- The stub must return data that exercises the code path being tested. A stub that returns empty arrays for everything does not validate that the code correctly parses and uses the LLM result.
- Tests that verify heuristic fallback paths (when the LLM is unavailable) should disable the LLM by clearing `ENV["OPENROUTER_API_KEY"]` in a `without_llm` block, not by making the stub return errors.
- `Fetchers::WebSearcher` Chromium calls are also stubbed to avoid browser launches. The stub lives in `LlmStubs.stub_web_searcher!`.
- To run tests against real LLM endpoints (integration verification), use: `OPENROUTER_API_KEY=sk-or-... bundle exec rails test`

## Key Architecture Decisions

- **No JavaScript frameworks.** UI is server-rendered with Turbo Streams. No React, no Vue, no Stimulus controllers beyond what Rails provides.
- **Tailwind CSS v4.** Propshaft pipeline with `tailwindcss-rails`. Custom theme in `app/assets/tailwind/application.css` with warm cream/brown palette. Utility-first classes in templates, minimal custom CSS for popovers and timeline.
- **SQLite in production.** WAL mode, tuned pragmas. No Postgres dependency.
- **LLM via OpenRouter.** Multi-model consensus through `RubyLLM` gem. Models configurable via `OPENROUTER_MODELS` env var.
- **Background jobs via Solid Queue.** Recurring jobs in `config/recurring.yml`.

## Link Extraction and Noise Filtering

`MainContentExtractor#extract_links` only extracts links from content-bearing elements (`<p>`, `<h2>`, `<h3>`, `<li>`) that contain at least 40 characters of non-link prose text. This filters out navigation chrome, subscription CTAs, topic tags, and other non-editorial links that many news sites wrap in `<p>` tags inside the article container.

The `UrlClassifier` rejects known non-article hosts (app stores, login subdomains, paywall subdomains, social media, e-commerce, etc.) to prevent noise in the evidence graph.

**When modifying link extraction or URL filtering:**

- Test changes against multiple outlets. Brazilian news sites (Folha, G1, UOL, Estadão) have very different HTML structures from international outlets (NBER, Reuters, NYT). A filter that cleans up one site's navigation chrome may accidentally remove real editorial citations from another.
- Run `bundle exec rails test` — the test suite includes extraction tests with realistic HTML from multiple outlet styles. Existing tests use inline citation links embedded in sentences (e.g., `<p>See the full breakdown in the <a href="...">Budget document</a> published last week.</p>`), not bare `<p><a>link</a></p>` blocks, because the extractor requires surrounding prose to distinguish editorial links from navigation.
- When adding a new noise pattern to `UrlClassifier` or `MainContentExtractor`, verify it doesn't match legitimate citation patterns. For example, `/login\./` catches `login.folha.com.br` but would also catch a hypothetical `login.gov` (which is a real US government site). Prefer specific patterns over broad ones.
- If a new outlet produces noisy links, first check whether the noise comes from the HTML structure (fix in `MainContentExtractor` selectors or `BLOCKED_SELECTORS`) or from the URLs themselves (fix in `UrlClassifier`). Prefer structural fixes over URL pattern matching.

## Code Conventions

- Services live in `app/services/` organized by domain (`analyzers/`, `fetchers/`, `llm/`, `parsing/`, `articles/`).
- Services use `.call` class method pattern delegating to `#call` instance method.
- Models use Rails enums with string backing and prefix option.
- Tests use Minitest, not RSpec. No mocking of database — integration tests hit real SQLite.

## Documentation

When adding or changing analysis sections, scores, pipeline steps, or report layout:

1. Update `README.md` with the new feature in the feature list.
2. Update `app/views/pages/methodology.html.erb` and the corresponding i18n keys in both `en.yml` and `pt-BR.yml` under `pages.methodology.*` — this is the user-facing "How to read a report" page.
3. Update `CLAUDE.md` if the change affects development workflow, core principles, or architecture.

The methodology page must always reflect the current report structure so readers can understand what each section and score means.

## i18n

All user-presentable text must use `t()` lookups — never hardcode strings in views, controllers, or helpers. Locale files live in `config/locales/` (`en.yml`, `pt-BR.yml`). When adding or changing any user-facing text:

1. Add the key to `config/locales/en.yml` under the appropriate namespace.
2. Add the corresponding pt-BR translation to `config/locales/pt-BR.yml` with proper Portuguese accents (á, ã, ç, é, ê, í, ó, õ, ú).
3. Use `t(".key")` shorthand in views (Rails resolves via template path) and `t("full.key.path")` in controllers/helpers.
4. Dates and times must use `l()` with format keys, never `strftime` with hardcoded format strings.

Locale is set via `FRANK_INVESTIGATOR_LOCALE` env var (defaults to `en`). Available: `en`, `pt-BR`.

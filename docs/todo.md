# Frank Investigator TODO

Last updated: March 11, 2026

This document tracks what is not implemented yet and what we learned so far that still needs to be turned into code.

## What is already implemented

These are not TODO items anymore.

- Rails 8 app scaffold with SQLite, Solid Queue, Turbo, Stimulus
- public URL intake flow at `/?url=...`
- canonical investigation records
- article graph with outbound in-body links
- root and linked article fetching through Chromium
- initial canonical-claim extraction and claim assessment pipeline
- idempotent pipeline step runner
- RubyLLM and OpenRouter integration seam with multi-model consensus support
- weighted evidence scoring
- Brazilian outlet source registry
- authority-specific connectors for government records, scientific papers, company filings, press releases
- Brazil-specific connectors for legislative pages, court pages, and market filing pages
- live smoke tasks for OpenRouter and Chromium fetch

## Highest-priority product gaps

### 1. Canonical claims are still too naive

Current state:

- claims are extracted with heuristics from title and early body sentences
- canonicalization is just a normalized fingerprint

Still needed:

- LLM-assisted claim decomposition for long or compound claims
- clustering of paraphrases across outlets and languages
- entity extraction and normalization
- numeric claim normalization
- time-scoped claim normalization
- speaker attribution on claims

Why this matters:

- the system will otherwise over-fragment repeated claims that use different wording

### 2. Evidence retrieval is still too article-centric

Current state:

- the crawler follows links in the article body
- authority-specific connectors enrich pages that are already discovered

Still needed:

- direct retrieval against authoritative sources, not only linked URLs
- query generation from claims into authority-specific endpoints
- targeted connectors for claims that mention laws, votes, filings, macro data, court rulings, or studies
- search fallback when an article cites no useful links

Why this matters:

- many weak or manipulative articles do not link the strongest primary evidence

### 3. Verdicting is still shallow

Current state:

- scoring uses weighted support/dispute evidence with authority and independence factors
- the LLM can synthesize over the evidence packet

Still needed:

- explicit score for evidence sufficiency
- explicit score for claim clarity
- explicit score for title-body mismatch severity
- stricter abstention rules when evidence is too thin
- stronger disagreement handling between the three LLM outputs
- explanation text grounded in exact evidence items rather than generic summary language

Why this matters:

- version 1 can still look more certain than it should on partial evidence

## Highest-priority crawler and parser gaps

### 4. Main-content extraction needs to become robust

Current state:

- extraction is heuristic and selector-based

Still needed:

- stronger article-body extraction for noisy Brazilian portals
- better exclusion of menus, trending lists, recommended links, and comment widgets
- persistent HTML snapshots for debugging extraction failures
- extraction quality tests against real article fixtures from UOL, g1, CartaCapital, Revista Oeste, Gazeta do Povo, VEJA, Folha, Estadao

### 5. Chromium stealth is still basic

Current state:

- Chromium is used with headless flags and a user-agent override

Still needed:

- session persistence and cookie handling
- randomized viewport and navigation pacing
- waiting strategies based on article readiness instead of a fixed virtual-time budget
- detection and handling of anti-bot interstitials
- optional remote-browser adapter if local Chromium becomes too brittle

### 6. Link traversal needs more policy

Current state:

- links are prioritized by source type and authority score
- recursion depth is limited

Still needed:

- per-host crawl budgets
- duplicate-content suppression across mirrored or syndicated pages
- canonical URL reconciliation across tracking and AMP variants
- explicit handling for document links such as PDF, DOCX, and spreadsheet evidence
- ability to stop following low-value newsroom self-links

## Brazil-specific work still needed

### 7. Brazilian primary-source connectors need to go deeper

Current state:

- basic authority detection exists for `gov.br`, `camara.leg.br`, `senado.leg.br`, `jus.br`, `cvm.gov.br`, `b3.com.br`, and RI-style filing pages

Still needed:

- connectors for Diario Oficial da Uniao and state/municipal official gazettes
- connectors for TCU, CGU, Receita Federal, Banco Central do Brasil, IBGE, Ipea, Anvisa, Inep, DataSUS
- connectors for STF/STJ/TSE/TRFs/TJs with docket and ruling metadata
- better extraction of law numbers, process numbers, relators, and publication dates
- Brazil-specific structured data retrievers instead of only HTML scraping

Why this matters:

- Brazilian institutional claims often need a cross-check from statistics, courts, regulatory filings, or official gazettes, not just ministry pages

### 8. Brazilian media evaluation needs explicit editorial-risk modeling

What we learned:

- Brazilian government portals can carry strong messaging bias
- major Brazilian outlets are relevant for reach and framing comparison, but not interchangeable with primary evidence

Still needed:

- separate `source authority` from `editorial slant risk`
- detect when multiple articles are just rewrites of one ministry statement
- cap confidence when corroboration is only within one editorial cluster
- track corporate/group ownership to avoid false independence

## U.S. authority work still needed

### 9. U.S. authority map is written down but not encoded

Current state:

- research exists in [docs/us_authorities.md](docs/us_authorities.md)

Still needed:

- source profiles for `govinfo`, `Congress.gov`, `Federal Register`, `Federal Reserve`, `FRED`, `BLS`, `Census`, `GAO`, `CBO`, `SEC EDGAR`, `U.S. Courts`, `PubMed`, `arXiv`, `NBER`
- source-role modeling:
  - official position
  - authenticated legal text
  - neutral statistics
  - oversight
  - research discovery
- score caps for White House, press releases, and preprints unless corroborated
- stronger U.S.-specific connectors for Federal Register documents, EDGAR filings, and federal court material

Why this matters:

- “U.S. government source” is too broad; we need role-aware trust

## LLM work still needed

### 10. RubyLLM is real, but most analysis is still heuristic-first

Current state:

- OpenRouter live smoke passed
- structured JSON schema is enforced for the assessment response

Still needed:

- LLM-powered claim decomposition
- LLM-powered query generation for authority-specific retrieval
- LLM-powered contradiction analysis between evidence items
- prompt sets specialized by source type
- model-by-model audit logging
- per-model latency, cost, and failure tracking
- cached LLM responses keyed by evidence packet fingerprint

### 11. Consensus logic needs to be stricter

Still needed:

- explicit consensus record per assessment
- preserve each model's raw structured output
- disagreement diagnostics shown in the UI
- lower confidence when one model refuses, one supports, and one disputes
- ability to quarantine one weak model without code surgery

## Data model and storage gaps

### 12. We still need durable provenance and reproducibility

Still needed:

- HTML snapshot storage
- fetched document attachments such as PDF and CSV
- checksum tracking for evidence items
- prompt and response persistence for every LLM call
- citation anchor offsets into article text or document sections
- versioned reassessment when evidence changes over time

### 13. We still need better independence modeling

Still needed:

- ownership groups for media companies
- source network clustering
- press-release propagation detection
- syndicated article detection
- “same source dressed as multiple sources” penalties

## UI and product gaps

### 14. The public page still needs a stronger analysis UX

Still needed:

- partial step-by-step live updates instead of refresh-based updates
- explicit “what we checked” and “what we could not check” cards
- evidence timeline
- graph view of article-to-article and article-to-claim links
- source authority explanation popovers
- headline bait explanation with concrete examples from title and body
- a better permalink model than only `/?url=...`

### 15. No moderation, abuse, or rate limiting yet

Still needed:

- URL submission rate limiting
- bad-host deny list
- SSRF protections review
- content size limits
- job budget limits per investigation
- failure states for hostile or broken pages

## Testing and quality gaps

### 16. We need more real fixtures

Still needed:

- saved HTML fixtures from Brazilian news sites
- saved HTML fixtures from U.S. official sources
- connector tests against real-world page shapes
- regression tests for canonicalization
- end-to-end tests that run the full investigation pipeline on fixture pages

### 17. We need live integration checks beyond smoke tasks

Still needed:

- scheduled smoke checks for OpenRouter
- scheduled smoke checks for Chromium fetch
- smoke checks for key Brazil hosts
- smoke checks for key U.S. authorities
- alerting when extraction shape changes on important hosts

## Research-derived rules we still need to encode

### 18. Source role must affect confidence

What we learned:

- White House and similar executive portals are good for official position, not neutral truth
- preprints are useful for discovery, not finality
- official gazettes and authenticated document repositories should outrank press summaries

Still needed in code:

- `source_role` separate from `source_kind`
- score caps based on source role
- stronger authenticated-document bonuses

### 19. Time-aware evidence is still weak

What we learned:

- evidence should be judged based on whether it existed at the time of the claim

Still needed in code:

- claim timestamp extraction
- article publication timestamp confidence
- reject or downgrade evidence that post-dates the claim when inappropriate
- timeline-aware verdict explanations

### 20. “Not checkable” must be stricter and more visible

What we learned:

- many article statements are framing, rhetoric, causality inflation, or opinion

Still needed in code:

- better classification of subjective statements
- separate label for “checkable but missing evidence” versus “not checkable in principle”
- UI copy that explains the distinction clearly

## Recommended implementation order from here

1. Encode U.S. authority profiles and connectors from [docs/us_authorities.md](docs/us_authorities.md)
2. Add Brazil official-gazette, court-docket, and regulator/statistics connectors
3. Store HTML snapshots, LLM prompts, LLM outputs, and evidence provenance
4. Add authority-specific retrieval beyond in-article links
5. Replace naive claim canonicalization with LLM-assisted decomposition and clustering
6. Add stronger independence and ownership modeling
7. Improve the analysis UI with evidence timelines and graph views

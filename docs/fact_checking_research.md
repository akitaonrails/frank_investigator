# Fact-Checking Methodologies: Industry Research & Gap Analysis

## 1. Industry Standards

### IFCN Code of Principles (Poynter)
Five commitments all signatories must satisfy:
1. **Nonpartisanship** — same standard regardless of who made the claim
2. **Transparency of sources** — enough detail for readers to replicate
3. **Transparency of funding** — funders cannot influence conclusions
4. **Transparency of methodology** — explain how claims are selected/researched/corrected
5. **Open corrections** — publish and follow a corrections policy

### ClaimBuster (UT Arlington)
Three-stage pipeline: claim spotting (SVM classifier, check-worthiness score), claim verification via QA systems, and repository matching against previously fact-checked claims.

### Full Fact AI
Pipeline: data collection → sentence atomization → claim classification (BERT) → claim matching (sentence vectors + entity analysis) → human verification with ClaimReview markup. Used by 40+ organizations across 30 countries.

### Google Fact Check Tools
Fact Check Explorer (search existing fact-checks) + ClaimReview structured data (schema.org). ClaimReview captures: claim text, who made it, reviewing org, verdict, URL.

---

## 2. Academic Consensus Pipeline

The standard computational fact-checking architecture (TACL 2022 survey, Guo et al.):

1. **Claim Detection** — is this sentence check-worthy?
2. **Evidence Retrieval** — document retrieval + sentence selection
3. **Verdict Prediction** — supported/refuted/NEI (natural language inference)
4. **Justification Production** (emerging) — human-readable explanations

Key techniques:
- Evidence retrieval: hybrid BM25 + dense retrieval (DPR, ColBERT)
- Verdict prediction: fine-tuned transformers (BERT, RoBERTa) on NLI formulation
- LLM approaches: RAG architectures, zero/few-shot prompting
- Claim matching: sentence transformers + NLI framing achieves F1 97%+

---

## 3. Source Credibility Frameworks

### CRAAP Framework
Currency, Relevance, Authority, Accuracy, Purpose — five dimensions for evaluating any source.

### Professional Fact-Checker Practices
- Assess every source's credibility and potential bias
- Corroborate through independent evidence
- Digital authentication (reverse image search, EXIF, geolocation)
- Source criticism: consider tendencies, biases, omissions
- Relate sources to other independent sources

---

## 4. Claim Lifecycle Management

Based on Full Fact's proposed schema:
1. Claim surfaces in media
2. ClaimReview published
3. FactCheckingRequest issued to claim author/publisher
4. Status tracking (pending, acknowledged, in progress)
5. Correction/retraction published
6. Request closed with outcome

Proposed schema includes `FactCheckingRequest` with agent, recipient, status, result, and timestamps. Distinguishes corrections (`CorrectionComment`) from full retractions (`RetractionComment`).

---

## 5. Evidence Provenance (W3C PROV Standard)

Three core concepts: Entity (data/evidence), Activity (process that produced it), Agent (who performed it). Relationships: derivation, usage, generation.

Practical techniques:
- SHA-256 hashing for content integrity
- Timestamping when evidence was captured
- Chain of custody documentation
- Web archiving (Wayback Machine) for point-in-time snapshots
- Content-addressable storage keyed by hash

---

## 6. Known Attack Vectors (USENIX Security 2023, 53 documented attacks)

### Adversarial Claim Attacks (38 known)
- Homoglyph substitution, Unicode tricks
- Date changes, synonym substitution, entity replacement
- Multi-hop reasoning requirements, temporal ambiguity
- Fact mixing (blending facts from multiple sources)
- Colloquial rephrasing (drops retrieval from 90% to 72%)
- LM-assisted paraphrasing with triggers

### Adversarial Evidence Attacks (13 known)
- Evidence camouflaging (typos, Unicode perturbations)
- Evidence planting (synthetic generation, Wikipedia vandalism)
- Claim-aligned rewriting using T5 models
- Neutral noise injection (high-BM25 neutral articles to dilute retrieval)

### Known Defenses (only 13 of 53 attacks have published defenses)
- Hybrid retrieval (dense + BM25)
- Contrastive data augmentation
- Causal interventions
- Natural logic-based multi-hop retrieval

---

## 7. Temporal Dynamics of Claims

- **Linguistic drift**: misinformation sentiment becomes more negative over time
- **Rumor resurgence**: false claims resurface with textual mutations; true claims don't
- **Feature instability**: detection models degrade across time periods
- **Timestamp-aware verification**: claim truth value can change over time

---

## 8. Cross-Referencing & Triangulation

Denzin's framework: data triangulation, investigator triangulation, theory triangulation, methodological triangulation.

Weighting considerations: proximity to event, track record, independence, expertise, potential bias, recency. Require minimum N independent sources before high-confidence verdict.

---

## 9. Retraction & Correction Tracking

Retraction Watch database: 63,000+ retractions linked to DOIs via Crossref. Monitoring: web diff tracking, RSS feeds, Crossref Event Data API. Key concern: "zombie claims" — debunked claims that continue circulating despite corrections.

---

## 10. Structured Argumentation (Toulmin Model)

Six components: Claim, Grounds (evidence), Warrant (logical connection), Backing (meta-evidence), Qualifier (confidence), Rebuttal (counter-evidence). Maps naturally to fact-checking pipeline stages.

Walton's argumentation schemes provide critical questions for common reasoning patterns (expert opinion, analogy, cause-effect).

---

## Gap Analysis: What Frank Investigator Has vs. What's Missing

### IMPLEMENTED (strong coverage)

| Capability | Implementation |
|---|---|
| Claim detection & extraction | ClaimExtractor (heuristic + LLM) |
| Claim normalization | ClaimCanonicalizer (SVO + semantic_key) |
| Claim deduplication | 4-stage: fingerprint → semantic_key → similarity → create |
| Evidence retrieval | EvidencePacketBuilder + ActiveEvidenceRetriever |
| Authority classification | AuthorityClassifier with US/Brazil source profiles |
| Multi-model LLM consensus | RubyLlmClient with weighted voting |
| Independence analysis | IndependenceAnalyzer (ownership clusters, syndication, PR propagation) |
| Temporal scoring | TemporalScoring with claim time ranges |
| Circular citation detection | CircularCitationDetector |
| Headline bait detection | HeadlineBaitAnalyzer with escalation patterns |
| Headline citation amplification | HeadlineCitationDetector |
| Primary source veto | apply_primary_veto in ClaimAssessor |
| Secondary weight cap | SECONDARY_WEIGHT_CAP = 0.8 |
| Unsubstantiated viral detection | unsubstantiated_viral? in ClaimAssessor |
| Rhetorical fallacy analysis | RhetoricalFallacyAnalyzer (10 fallacy types) |
| Verdict history & audit trail | VerdictSnapshot with evidence state capture |
| Staleness detection & reassessment | StalenessDetector + recurring jobs |
| Content extraction robustness | MainContentExtractor with noise filtering |
| Error reporting | ErrorReport with DB + optional Sentry/Honeybadger |

### GAPS — Prioritized by Impact on Claim Robustness

#### HIGH PRIORITY

**1. Source Retraction & Correction Monitoring**
- Status: NOT IMPLEMENTED
- Problem: If a source we relied on publishes a correction or retraction, we don't know. Our verdict stays based on the original (now-corrected) evidence.
- Industry standard: Retraction Watch, web diff monitoring, RSS correction feeds
- Recommendation: Track article content fingerprints over time. On re-crawl, detect body changes. If an evidence article's body changes significantly after assessment, flag the assessment as stale with reason "source_corrected".

**2. Evidence Provenance Chain**
- Status: PARTIAL (we store fetched_at, content_fingerprint, but no formal chain)
- Problem: We can't prove when we saw what. An article could change after we assessed it, and we have no archived snapshot to compare.
- Industry standard: W3C PROV model, SHA-256 + timestamp, content-addressable storage
- Recommendation: We already have HtmlSnapshot model. Ensure every evidence article has a snapshot. Add `content_hash_at_assessment` to VerdictSnapshot so we can detect if evidence changed since assessment.

**3. Claim Mutation Tracking (Zombie Claims)**
- Status: NOT IMPLEMENTED
- Problem: A debunked claim resurfaces with slight textual mutations ("GDP grew 5%" → "GDP grew nearly 5%" → "GDP surged"). Each mutation might create a new claim instead of linking to the existing debunked one.
- Industry standard: Track claim variants as mutation chains, rumor resurgence detection
- Recommendation: When a new claim matches an existing one at similarity 0.5-0.7 (below dedup threshold), link it as a `claim_variant` rather than treating it as fully independent. Inherit the parent claim's assessment history as context.

**4. Adversarial Input Hardening**
- Status: NOT IMPLEMENTED
- Problem: Homoglyph attacks (Cyrillic 'а' vs Latin 'a'), Unicode normalization tricks, and entity substitution can bypass claim deduplication.
- Industry standard: NFKC normalization, homoglyph detection, entity-aware matching
- Recommendation: Add Unicode NFKC normalization to ClaimFingerprint and text processing. Add confusable character detection (ICU confusables.txt).

#### MEDIUM PRIORITY

**5. Structured Argumentation (Warrant Assessment)**
- Status: PARTIAL (we assess stance but not reasoning quality)
- Problem: We determine if evidence supports/disputes a claim but don't evaluate whether the logical connection (warrant) is sound. An article could "support" a claim using flawed reasoning.
- Industry standard: Toulmin model warrant assessment, NLI-based verification
- Recommendation: Extend EvidenceRelationshipAnalyzer's LLM prompt to also evaluate warrant quality: "Does the evidence logically connect to the claim, or does it merely correlate?"

**6. Source Track Record Scoring**
- Status: NOT IMPLEMENTED
- Problem: We score source authority by host/type but not by historical accuracy. A news outlet that has been frequently wrong should be weighted lower.
- Industry standard: Track record databases, outlet accuracy scoring
- Recommendation: Track per-host accuracy over time. When a source's claims are frequently disputed in later assessments, reduce its authority_score for future investigations.

**7. ClaimReview Schema Output**
- Status: NOT IMPLEMENTED
- Problem: Our verdicts aren't in a standard format that other fact-checking tools can consume.
- Industry standard: schema.org ClaimReview markup
- Recommendation: Generate ClaimReview JSON-LD for each completed assessment. Embed in investigation show page for Google Fact Check Explorer indexing.

**8. Bias Detection in Claim Selection**
- Status: NOT IMPLEMENTED
- Problem: IFCN requires nonpartisanship. If our system disproportionately selects claims from one political side, it violates the core principle.
- Industry standard: Monitor claim selection distribution across political spectrum
- Recommendation: Track entity/topic distribution in assessed claims. Alert if >70% of claims in a period relate to one political entity/party.

#### LOWER PRIORITY

**9. Multi-Hop Evidence Reasoning**
- Status: NOT IMPLEMENTED
- Problem: Some claims require chaining evidence: "A implies B, B implies C, therefore A implies C." We only do single-hop (does this article relate to this claim?).
- Industry standard: Multi-hop retrieval (AdMIRaL), knowledge graph traversal
- Recommendation: Future enhancement. Current single-hop is adequate for most news claims.

**10. Cross-Language Claim Matching**
- Status: NOT IMPLEMENTED
- Problem: Same claim in English and Portuguese treated as separate claims.
- Recommendation: Use LLM translation in ClaimSimilarityMatcher for cross-language equivalence. Lower priority since most investigations are single-language.

**11. Image/Video Evidence Authentication**
- Status: NOT IMPLEMENTED
- Problem: We only analyze text. Fact-checking increasingly involves verifying images, videos, and screenshots.
- Recommendation: Out of scope for current text-focused pipeline. Could add reverse image search integration later.

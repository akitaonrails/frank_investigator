# Frank Investigator — Distributed Architecture Plan

## Status: DRAFT — Design phase, not yet implemented

## Problem Statement

A centralized fact-checking service is a single point of failure:
- **Technical**: one server down = service offline
- **Political**: one takedown notice to one hosting provider, one domain registrar, or one DNS provider kills the entire system
- **Legal**: one jurisdiction's laws can compel removal of all content

The goal is a distributed network where shutting down any single node (or any group of nodes) does not destroy the system's ability to serve reports.

---

## Architecture Overview

### Two-Tier Node System

**Investigator Nodes** (trusted, generate reports)
- Run the full 15-step analysis pipeline (Chromium, LLM, web search)
- Sign reports with their Ed25519 private key
- Expensive to operate (LLM API costs, compute for Chromium)
- Small number, curated membership

**Mirror Nodes** (anyone, cache-only)
- Cannot generate new investigations
- Fetch and cache signed reports from investigator nodes
- Serve cached reports to users
- Verify signatures before caching (reject unsigned/invalid reports)
- Cheap to operate (no LLM keys, no Chromium, minimal compute)
- Large number, open membership

```
INVESTIGATOR NODES (trusted, full pipeline)
┌──────────────┐     ┌──────────────┐
│ Node A       │◄───▶│ Node B       │
│ Full pipeline│     │ Full pipeline│
│ Signs reports│     │ Signs reports│
└──────┬───────┘     └──────┬───────┘
       │                    │
       ▼                    ▼
MIRROR NODES (anyone, cache-only)
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│ Mirror X     │◄───▶│ Mirror Y     │◄───▶│ Mirror Z     │
│ Cache + serve│     │ Cache + serve│     │ Cache + serve│
│ Verify sigs  │     │ Verify sigs  │     │ Verify sigs  │
└──────────────┘     └──────────────┘     └──────────────┘
```

### Report Identity

Reports are addressed by `sha256(normalized_url)` — the article URL hash, not the report content hash. This is because:
- Two investigator nodes analyzing the same URL will produce similar but not identical reports (LLM outputs vary)
- Multiple versions of the same analysis existing is acceptable and even desirable (shows analysis isn't dogma)
- When a mirror fetches a report, it gets the version from whichever investigator node responds first (or the most trusted one)

### Report Resolution Flow

```
1. User requests /investigations/{url_hash}
2. Node checks local DB → found? Serve it.
3. Not found → ask known peers in parallel (with timeout)
4. Peer responds with signed report
5. Verify signature against known investigator public keys
6. Cache locally, serve to user
7. Background: announce availability to other mirrors
```

---

## Peer Protocol

### Endpoints

```
GET  /api/v1/network/peers          — list known peers
GET  /api/v1/network/investigators  — list trusted investigator public keys
GET  /api/v1/network/reports/{hash} — fetch a report by URL hash
POST /api/v1/network/announce       — announce new report availability
```

### Peer Discovery

- Bootstrap list of known peers (hardcoded + configurable via env)
- Each node publishes its peer list at `/api/v1/network/peers`
- Nodes gossip: connecting to peer A reveals peers B, C
- Dead peers pruned after N consecutive failed health checks
- No central peer registry

### Report Announcement

When an investigator node completes a report:
1. Sign the report JSON with Ed25519 private key
2. Compute `sha256(normalized_url)` as the report address
3. Store locally with signature and public key
4. Announce to known peers: "I have report for {url_hash}"

Mirrors that receive an announcement can choose to:
- Pre-fetch and cache (eager replication)
- Note the availability and fetch on demand (lazy replication)

---

## Cryptographic Signing

### Per-Node Identity

Each node generates an Ed25519 keypair on first boot:
- Private key: stored locally, never transmitted
- Public key: published at `/api/v1/network/identity`
- Used to sign every report the node generates

### Report Signature

A signed report contains:
```json
{
  "report": { ... full investigation JSON ... },
  "meta": {
    "url_hash": "sha256 of the article URL",
    "investigator_key": "ed25519 public key",
    "signature": "ed25519 signature of report JSON",
    "created_at": "ISO 8601 timestamp",
    "node_version": "software version that generated this"
  }
}
```

Mirror nodes verify the signature before caching. Invalid signatures are rejected.

---

## Open Problems

### 1. Trust System (CRITICAL — NO OBVIOUS SOLUTION YET)

The weakest link in the entire architecture. The two-tier system (investigators vs mirrors) prevents random actors from injecting fake reports, but the question becomes: **who decides who is a trusted investigator?**

#### Option A: Vouching chain
- Root node (the project creator) vouches for initial investigators
- Each investigator can vouch for new investigators
- Revocation requires majority of existing investigators

**Flaw**: One bad vouching decision cascades — a compromised investigator vouches for malicious nodes, which vouch for more malicious nodes. A single mistake can compromise the network.

#### Option B: Proof of work / stake
- New investigators must demonstrate competence (e.g., run for N months with quality reports)
- Existing investigators can flag quality issues

**Flaw**: Slow onboarding. A well-funded adversary can invest the time.

#### Option C: Web of trust (PGP-style)
- No central authority — each mirror operator decides which investigators to trust
- Users see "This report was signed by Key X, which your node trusts"
- Different mirrors may trust different investigators

**Flaw**: Complex UX. Most users won't understand or configure trust settings. Defaults determine everything, and whoever controls defaults controls the network.

#### Option D: Federated consensus
- A fixed set of founding investigators (like blockchain validators)
- New investigators admitted by supermajority vote
- Revocation by supermajority vote

**Flaw**: Becomes a political body. Who watches the watchers?

#### Option E: Transparent disagreement
- Don't try to prevent bad reports — let them exist
- When two investigator nodes produce conflicting analyses of the same article, show BOTH to the user
- Let the reader evaluate which analysis is more thorough
- The system's value is the methodology, not the verdict

**Flaw**: A flood of low-quality reports drowns the good ones.

**Current thinking**: No single option is sufficient. The most robust approach may be a combination:
- Small founding group with vouching (Option A) for initial network
- Transparent disagreement (Option E) as the philosophical foundation
- Reputation scoring based on analysis quality metrics (not manual curation)
- Any mirror can choose to filter by investigator reputation threshold

**This is the hardest problem and must be solved before implementation.**

### 2. Report Versioning

An investigation can be updated:
- Cross-reference enrichment adds event context
- Honest headline is generated after initial analysis
- Re-analysis with improved prompts

Each version has the same URL hash but different content. Options:
- Immutable reports: each version gets a sequence number, mirrors cache the latest
- Append-only: new versions don't replace old ones, they extend them
- Timestamp-based: mirrors always prefer the most recent version from the most trusted investigator

### 3. Spam and Flooding

A malicious actor could:
- Generate thousands of garbage reports (if investigator)
- Flood the announcement protocol with fake availability claims (if mirror)
- DDoS specific mirrors to prevent access to reports about specific topics

Mitigations:
- Rate limiting on announcements
- Reputation scoring penalizes high-volume/low-quality investigators
- Mirrors can set maximum cache size and LRU eviction
- Report generation is expensive (LLM calls) which naturally rate-limits investigators

### 4. Legal Exposure

Each mirror operator serves content they didn't create. Legal concerns:
- Defamation claims against report content
- Government orders to remove specific reports
- GDPR/privacy requests about people mentioned in reports

Mitigations:
- Reports are clearly labeled as automated analysis, not editorial claims
- Terms of Service page is served alongside every report
- Mirror operators can choose to not cache specific reports (opt-out, not opt-in)
- The distributed nature means removing a report from one mirror doesn't remove it from others

### 5. Network Partition

If the network splits (e.g., one country blocks all known peers):
- Nodes in the partition can still serve locally cached reports
- New reports from outside the partition won't be available until connectivity is restored
- Bootstrap peers should be geographically and jurisdictionally diverse

### 6. Resource Asymmetry

Investigator nodes are expensive (LLM costs, compute). Mirror nodes are cheap. This means:
- The network's analysis capacity is limited by the number of investigator nodes
- A well-funded adversary can outspend the investigator network
- There's no economic incentive to run an investigator node (it costs money)

This is similar to Wikipedia's model: a small number of active editors do the work, funded by donations. The distributed architecture protects the distribution, not the production.

---

## Implementation Phases

### Phase 1: Report Freezing + Signing (can ship independently)
- Ed25519 keypair generation on first boot
- Freeze investigation as signed JSON on completion
- Store `url_hash`, `signature`, `investigator_public_key` alongside the report
- Serve at `/investigations/{url_hash}` as an alias
- **No network changes** — pure local enhancement

### Phase 2: Peer Protocol
- HTTP API for peer discovery and report resolution
- Mirror mode: `FRANK_MODE=mirror` disables pipeline, enables caching
- Report fetching from peers with signature verification
- Configuration: `FRANK_PEERS=node-a.com,node-b.com`

### Phase 3: Mirror Node Package
- Stripped Docker image (no Chromium, no LLM dependencies)
- One-command setup for anyone to run a mirror
- Auto-discovers investigators, syncs their public keys
- Minimal resource requirements (Raspberry Pi viable)

### Phase 4: Trust Network (requires solving the open trust problem)
- Vouching/revocation protocol
- Reputation scoring
- Multi-party consensus for investigator admission/revocation
- **Do not implement until the trust model is designed and stress-tested**

---

## What Does NOT Change

- The entire 15-step analysis pipeline
- The report page UI
- The JSON API format
- SQLite storage
- LLM integration
- Kamal deployment (for investigator nodes)
- The Terms of Service and methodology pages

The distributed layer is additive — it wraps the existing system, it doesn't replace it. A node running without any peers is just the current Frank Investigator.

---

## References and Inspiration

- **Nostr**: Decentralized social protocol. Relays (mirrors) are open, clients choose which relays to trust. No content moderation at the protocol level.
- **IPFS**: Content-addressable storage. Data identified by hash, distributed across nodes. Good for immutable content.
- **ActivityPub/Mastodon**: Federated model. Each server has an operator who makes moderation decisions. Users choose which server to trust.
- **PGP Web of Trust**: Decentralized trust without central authority. Each participant decides who to trust. Complex but proven.
- **Bitcoin**: Proof of work prevents spam. Expensive to attack. But energy-intensive and slow.

The closest model is probably **Nostr + PGP Web of Trust**: content is signed and distributed through relays, trust is per-user rather than system-wide.

---

## Decision Log

| Decision | Status | Notes |
|----------|--------|-------|
| Two-tier architecture (investigators + mirrors) | ACCEPTED | Prevents random injection while allowing open distribution |
| Address by URL hash, not report hash | ACCEPTED | Same URL = same event, different analyses are okay |
| Ed25519 for signing | PROPOSED | Standard, fast, small keys |
| Trust model | OPEN | Critical unsolved problem — see section above |
| Mirror mode as stripped Docker image | PROPOSED | Lowers barrier to running a mirror |
| Report versioning strategy | OPEN | Need to decide immutable vs append-only |

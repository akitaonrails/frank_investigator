# U.S. Authority Map For Fact-Checking

Last updated: March 11, 2026

## Why this exists

If Brazilian government portals are treated as high-authority but are editorially slanted or selective, the answer is not to stop using primary sources. The answer is to separate source roles more carefully:

- official position sources
- authenticated legal text sources
- neutral statistical sources
- oversight and audit sources
- research discovery sources

This map is for that split on the U.S. side.

## Main recommendation

Do not treat `whitehouse.gov` as a general neutral truth source.

As of March 11, 2026, the White House website reflects the sitting administration's messaging and priorities. That makes it useful for:

- official statements
- executive intent
- press releases
- policy announcements

It should not be the sole source for:

- whether a measure is legally in force
- whether an economic claim is true
- whether a scientific claim is well supported

For those, prefer the sources below.

## Best U.S. authorities by use case

### 1. Executive claims and presidential actions

#### White House

Use for:

- official presidential statements
- signing statements
- administration press releases
- OMB and executive-branch position pages

Do not use alone for:

- legal force
- implementation status
- neutral background

Sources:

- White House homepage: https://www.whitehouse.gov/
- White House executive branch overview: https://www.whitehouse.gov/government/executive-branch/
- OMB: https://www.whitehouse.gov/omb/

System rule:

- classify as `official_position`, not `neutral_fact`
- always try to pair with `Federal Register` or `govinfo` if the claim is about binding action

### 2. Authenticated legal and regulatory text

#### govinfo

This is one of the strongest sources for legal/authenticated federal documents. GovInfo says it provides free public access to official publications from all three branches of the federal government, and it also describes itself as a standards-compliant preservation repository. GPO also explains that many PDFs carry digital signatures to provide evidence of authenticity and integrity.

Use for:

- authenticated Federal Register documents
- Congressional documents
- presidential documents
- Code of Federal Regulations
- congressional hearings and reports

Sources:

- About GovInfo: https://www.govinfo.gov/about
- Authentication on GovInfo: https://www.govinfo.gov/about/authentication

System rule:

- top-tier source for official federal text
- if an article claims a rule, order, or notice exists, try `govinfo` first

#### Federal Register

Use for:

- proposed rules
- final rules
- executive orders
- notices
- regulatory actions

Important note:

- FederalRegister.gov is extremely useful for search and browsing
- when the document itself says “the official version ... is the document published in the Federal Register” and points users to `govinfo.gov`, treat `govinfo` as the authenticated copy and `FederalRegister.gov` as the easier discovery layer

Source example showing this relationship:

- Federal Register document text referencing official edition on GovInfo: https://www.federalregister.gov/documents/full_text/html/2025/05/21/2025-09093.html

System rule:

- discovery source for regulations
- pair with `govinfo` for final authoritative storage and authenticity

### 3. Legislation and congressional process

#### Congress.gov

Congress.gov says it is the official website for U.S. federal legislative information, maintained by the Library of Congress using House and Senate source data.

Use for:

- bill status
- amendments
- roll call context
- sponsor and committee information
- congressional record discovery

Source:

- About Congress.gov: https://www.congress.gov/about

System rule:

- top source for “did Congress pass or introduce this?”
- if the claim is about enacted statutory text, also cross-check `govinfo`

### 4. Budget scoring and neutral fiscal analysis

#### Congressional Budget Office (CBO)

CBO is one of the best alternatives when the question is fiscal impact, budget scorekeeping, or medium-term policy cost. CBO describes its role as providing objective, nonpartisan information to support the budget process and explicitly says it makes no policy recommendations.

Use for:

- budgetary impact of bills
- macroeconomic and fiscal baselines
- long-term cost estimates
- federal program cost comparisons

Sources:

- CBO mission document: https://www.cbo.gov/system/files/2025-04/61287-CBO-Mission.pdf
- Example testimony describing CBO as objective and nonpartisan: https://www.cbo.gov/system/files/2024-09/60439-Oversight-Testimony.pdf

System rule:

- top-tier source for fiscal claims
- stronger than White House or partisan think-tank summaries for budget effects

### 5. Oversight, audits, and implementation reality

#### GAO

GAO describes itself as an independent, non-partisan agency that works for Congress and provides objective, fact-based information. This is one of the best sources when the issue is whether a federal program actually worked as claimed.

Use for:

- audits
- implementation gaps
- fraud, waste, or abuse findings
- program performance
- technology assessments

Sources:

- About GAO: https://www.gao.gov/about
- What GAO does: https://www.gao.gov/about/what-gao-does
- Reports: https://www.gao.gov/for-congress/reports

System rule:

- top-tier source for “did the government actually do what it said?”
- especially useful to check claims made by agencies or the White House

### 6. Monetary policy, banking, and macro-financial claims

#### Federal Reserve Board

The Federal Reserve says it is the central bank of the United States and describes its five core functions around monetary policy, financial stability, supervision, payments, and consumer/community development.

Use for:

- interest rate and monetary policy claims
- bank supervision claims
- financial stability claims
- official statistical releases

Sources:

- About the Fed: https://www.federalreserve.gov/aboutthefed/mission.htm
- Data Download Program help: https://www.federalreserve.gov/datadownload/help/

System rule:

- top-tier primary source for monetary-policy and banking claims
- prefer Board releases over commentary about Board releases

#### FRED

FRED is excellent for reproducible economic time series and historical comparisons. The St. Louis Fed says FRED contains frequently updated macro and regional time series and aggregates data from many sources, mostly U.S. government agencies.

Use for:

- retrieving economic series cleanly
- comparing time series across releases
- charting labor, inflation, rates, money, output

Source:

- What is FRED: https://fred.stlouisfed.org/docs/api/fred/fred.html

System rule:

- treat as a structured data layer
- still preserve the original source agency for provenance when available

### 7. Official statistics

#### BLS

BLS says it is the principal fact-finding agency in labor economics and statistics and part of the U.S. Federal Statistical System. This is one of the best neutral sources for labor-market and inflation-related claims.

Use for:

- CPI
- payrolls
- unemployment
- wages
- productivity

Source:

- About BLS: https://www.bls.gov/bls/about-bls.htm

System rule:

- top-tier source for labor and price claims

#### Census Bureau

Census is a strong primary source for demographic, housing, household, business, and survey-based claims.

Use for:

- population
- household and demographic data
- ACS-based claims
- business survey claims

Source:

- About the U.S. Census Bureau: https://www.census.gov/about-us

System rule:

- top-tier source for demographic and household claims

### 8. Courts and judicial process

#### U.S. Courts

The U.S. Courts site is maintained by the Administrative Office of the U.S. Courts on behalf of the federal judiciary. It is useful for structure, reports, and judiciary administration, but case-level verification often requires PACER or the court docket itself.

Use for:

- judiciary structure
- official court reports
- federal judiciary statistics
- administrative and procedural context

Sources:

- U.S. Courts homepage: https://www.uscourts.gov/
- About district courts: https://www.uscourts.gov/about-federal-courts/court-role-and-structure/about-us-district-courts
- Judicial Conference: https://www.uscourts.gov/administration-policies/governance-judicial-conference/about-judicial-conference-united-states

System rule:

- strong source for court system context
- for a specific case, do not stop at summary pages if a docket or order is available

### 9. Securities filings and public-company claims

#### SEC EDGAR

EDGAR is one of the best primary-source systems for public-company claims. The SEC describes EDGAR as the primary system for companies and others submitting documents under federal securities laws.

Use for:

- 8-K, 10-K, 10-Q, 20-F, proxy materials
- insider forms
- offering documents
- real-time company filing verification

Sources:

- About EDGAR: https://www.sec.gov/submit-filings/about-edgar
- Accessing EDGAR data: https://www.sec.gov/edgar/searchedgar/accessing-edgar-data.htm

System rule:

- top-tier primary source for claims about public companies
- prefer the official HTML/text filing over screenshots or summaries

### 10. Biomedical and life-sciences literature

#### PubMed

PubMed is a strong discovery layer maintained by NCBI at NIH/NLM. It is excellent for finding peer-reviewed biomedical literature, but it is a discovery/index resource, not itself the full authority on every paper.

Use for:

- biomedical literature discovery
- linking claims to indexed studies
- finding review papers and trial references

Source:

- About PubMed: https://pubmed.ncbi.nlm.nih.gov/about/

System rule:

- use for discovery and metadata
- if possible, read the linked full text or PubMed Central copy before scoring a claim strongly

### 11. Open research discovery

#### arXiv

arXiv is strong for early scientific discovery and technical fields, but it is not peer review. arXiv’s own materials frame it as an open platform for sharing and discovering emerging science, with Cornell stewardship.

Use for:

- fast discovery in physics, math, CS, AI, quantitative social science
- early signal detection
- tracing technical claims before journal publication

Sources:

- arXiv annual report mission/vision page: https://info.arxiv.org/about/reports/2023_arXiv_annual_report.pdf

System rule:

- classify as `preprint`
- never treat alone as settled evidence for high-stakes medical or policy claims

### 12. Non-government research institutions

#### NBER

NBER is not a government source, but it is a strong economics institution. NBER says it is a private, nonprofit, nonpartisan organization and emphasizes that it refrains from making policy recommendations.

Use for:

- economic working papers
- business cycle dating context
- empirical economics research

Sources:

- About NBER: https://www.nber.org/about-nber
- History and non-recommendation rule: https://www.nber.org/about-nber/history

System rule:

- strong supporting institution for economics
- still below official statistical agencies for raw official numbers

## Practical ranking for Frank Investigator

This is my recommended default ranking.

### Tier A: authenticated primary

- govinfo
- Congress.gov
- Federal Reserve Board
- BLS
- Census
- SEC EDGAR
- U.S. Courts or direct court docket
- agency-origin official datasets

### Tier B: primary but political or role-limited

- White House
- OMB
- agency press offices
- agency blogs or explainer pages

### Tier C: independent institutional oversight

- GAO
- CBO

### Tier D: research discovery and scholarly support

- PubMed
- arXiv
- NBER

## Recommended product rule

For U.S.-related claims, require at least one of these patterns before raising confidence above medium:

- one Tier A source
- or one Tier C source plus one Tier A source
- or two independent Tier A sources

For claims sourced only to:

- White House
- a press release
- a preprint

cap the score unless corroborated elsewhere.

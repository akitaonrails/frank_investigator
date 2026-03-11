# Frank Investigator

Frank Investigator is a Rails 8 news fact-checking system built around canonical claims, evidence graphs, and citation-grounded analysis.

Version 1 goals:

- accept a public news article URL from a simple homepage form
- normalize the URL and redirect to a shareable analysis page at `/?url=...`
- fetch the page with Chromium, extract the main article body, and follow in-article links
- derive canonical claims from the article and link those claims back to every article that repeats or cites them
- score what is checkable, what is not checkable, how much evidence supports each conclusion, and how baity the headline is relative to the article body
- orchestrate the pipeline with Rails-native components, especially Active Job and SQLite-backed queueing

Project docs:

- [Research summary](docs/research.md)
- [Technical architecture](docs/architecture.md)
- [U.S. authority map](docs/us_authorities.md)
- [Implementation TODO](docs/todo.md)

Initial audience focus:

- Brazil-first source profiling and testing for outlets such as UOL Noticias, g1, CartaCapital, Revista Oeste, Gazeta do Povo, VEJA, Folha, Estadao, and Agencia Brasil

## Stack

- Ruby 4.0.1
- Rails 8.1
- SQLite3
- Solid Queue, Solid Cache, Solid Cable
- Importmap, Turbo, Stimulus

## Product shape

The homepage is intentionally simple. A user submits a URL, and Frank Investigator either finds or creates the corresponding investigation and redirects to the canonical analysis URL:

```text
https://frankinvestigator.com/?url=https%3A%2F%2Fsomenews.com%2Farticles%2F1
```

The analysis page should clearly separate:

- checkable claims
- not-checkable claims
- evidence still missing
- title bias and bait score
- overall confidence and why the system reached that confidence level

## Architecture principles

- canonical claims are first-class records, not transient prompt output
- articles, claims, evidence, and follow-up links form a graph we can revisit
- every pipeline step must be idempotent
- Active Job fan-out is acceptable only when step ownership and deduplication are explicit
- service objects should stay small, isolated, and unit-testable
- the LLM is a planner and synthesizer over evidence, not the only source of truth

## Status

This repository was bootstrapped from scratch on March 11, 2026. The next implementation layers are the first schema, pipeline jobs, Chromium fetching adapter, and the initial public submission flow.

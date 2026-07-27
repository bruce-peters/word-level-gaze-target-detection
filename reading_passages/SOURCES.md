# Reading passages for word-level gaze testing

Six public-domain excerpts, each a single contiguous quotation (no internal
cuts) chosen to end on a natural sentence/paragraph boundary, so the passage
reads as a complete unit without requiring the reader to jump between
disconnected sections. All were pulled from Project Gutenberg (or, for
Finnegans Wake, cross-checked against a second scholarly transcription) and
reflowed to plain text — no OCR artifacts, no italics markup.

| # | File | Tier | Author / Work | Words | US copyright status |
|---|------|------|----------------|-------|----------------------|
| 1 | `1_easy_winnie_the_pooh.txt` | Easy | A. A. Milne, *Winnie-the-Pooh* (1926), ch. 1 | 653 | Public domain (US) since Jan 1, 2022 |
| 2 | `2_medium_alice_in_wonderland.txt` | Medium | Lewis Carroll, *Alice's Adventures in Wonderland* (1865), ch. 1 opening | 503 | Public domain |
| 3 | `3_medium_faraday_chemical_history_of_a_candle.txt` | Medium (science) | Michael Faraday, *The Chemical History of a Candle* (1861), Lecture I | 582 | Public domain |
| 4 | `4_hard_henry_james_the_ambassadors.txt` | Hard | Henry James, *The Ambassadors* (1903), opening of Book First | 627 | Public domain |
| 5 | `5_hard_darwin_origin_of_species.txt` | Hard (science) | Charles Darwin, *On the Origin of Species*, 1st ed. (1859), ch. 3 | 616 | Public domain |
| 6 | `6_extra_hard_joyce_finnegans_wake.txt` | Extra hard | James Joyce, *Finnegans Wake* (1939), opening pages | 623 | **Not yet PD in the US** (protected through 2034); PD in UK/EU/Canada/Australia since 2012 (life+70, Joyce d. 1941). Used here as a short, widely-quoted excerpt for internal research/testing only — do not redistribute publicly. |

## Why each was picked

**1. Winnie-the-Pooh (easy).** Short declarative sentences, concrete
vocabulary, a single linear narrative (Pooh hears buzzing, climbs the tree,
falls, asks Christopher Robin for a balloon). Almost no subordinate clauses,
so there's little reason for a reader's eyes to backtrack. Deliberately a
different text from the Tortoise-and-the-Hare fable already hardcoded in
`web_app/app.js`, so you get a second easy-tier data point rather than
re-using the placeholder.

**2. Alice in Wonderland (medium).** Victorian narrative prose — longer
sentences than Pooh, occasional inverted syntax and dashes, but still a
single clear thread (Alice sees the White Rabbit, follows it down the hole,
falls). Vocabulary is mostly familiar with a few dated words
("waistcoat-pocket," "daisy-chain").

**3. Faraday's candle lecture (medium, science).** This was a live lecture
to a lay audience (including children), so it's expository science with
plain diction, but the sentences are long, comma-heavy Victorian
constructions with nested clauses — a step up in syntactic load from
Alice while staying conceptually simple (what candles are made of).

**4. Henry James, *The Ambassadors* (hard).** The opening paragraphs of the
novel Edmund Wilson called James's most difficult. Deeply embedded clauses,
delayed subjects, and free indirect discourse mean a reader often has to
hold a sentence's beginning in mind for 60+ words before it resolves. This
is "hard for advanced readers" by reputation, not obscure vocabulary — the
words are ordinary, the syntax is the obstacle.

**5. Darwin, *On the Origin of Species*, ch. 3 (hard, science).** The
"Struggle for Existence" chapter, first edition (1859) — denser and more
qualified than the popularizations of Darwin you usually see quoted. Long
chains of subordinate clauses building a single argument (the elephant
population calculation), with period-specific scientific vocabulary
("geometrical increase," "prudential restraint").

**6. Finnegans Wake (extra hard).** The single most famous opening in
English-language literature to defy ordinary reading, by design. Portmanteau
words, invented language, and the 100-letter thunderclap word
("bababadalgharaghtakamminarronnkonnbronntonnerronntuonnthunntrovarrhounawnskawntoohoohoordenenthurnuk!")
mean fixation durations and regressions should spike dramatically here —
useful as a ceiling/stress-test condition. Text was cross-checked between an
OCR transcription (archive.org) and a manually annotated scholarly edition
(finwake.com) to catch OCR corruption — a few OCR errors were found and
corrected this way (e.g. "hayre in bonds" was OCR noise for the actual
"hayre in honds"; a stray page-number artifact in "waalworth 7^*14" was
removed).

## Note on "jumping"

All six are single excerpts ending on a real sentence or paragraph boundary
— nothing was spliced from two different parts of a book. The *difficulty*
in tiers 4–6 is deliberately syntactic/lexical (long-range dependencies
within sentences), not structural (no need to jump between unrelated
sections). Any regressions your app measures on these passages should
reflect real reading difficulty, not artifacts of the excerpting.

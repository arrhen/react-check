# Contributing

The most useful contribution is a real label that the app gets wrong.

1. Add a case to `Tests/ReactCheckCoreTests/Golden/golden.json` with the label text, a profile, and the expected result.
2. Fix the data in `Sources/ReactCheckCore/Resources/allergens.json` or `phrases.json`.
3. `swift test` must pass.

## Data syntax

Terms default to substring matching. `=term` is whole word (plural allowed). `!term` is excluded from fuzzy matching. Non-Latin terms are always substring.

Every `=` term and every exclusion needs a golden test showing why.

## Languages

Non-English terms are a first draft. Native speakers: please review, add terms, and add real labels in your language.

## Safety rule

A change must never make the app less likely to flag an allergen without a test showing the flagged text is not that allergen.

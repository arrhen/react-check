# React Check: specification

React Check is a free, open-source iOS app that reads a food label with the camera and tells you whether anything on it matches the allergies or intolerances of the people you cook for. It is an aid. It never replaces reading the label.

## 1. Safety principles

These are requirements, not preferences. A change that breaks one is a bug.

1. **Fail safe.** Any uncertainty moves the result toward more caution, never less.
2. **Three verdicts, decided per profile, never "safe".**
   - `matchesFound(level)`: this profile has at least one match.
   - `cannotVerify`: nothing matched for this profile, but the read was not good enough to say so. Shown as "Couldn't read this reliably. Check the label yourself."
   - `noMatchesFound`: a good read of a full ingredient list found no matches for this profile. Shown as "No matches found. This is not a safety guarantee. Please read the label yourself." Never green, never a tick, never the word "safe".
   - On an unreliable read, a profile that has matches also carries `mayBeMore`: "there may be more you couldn't see". A mild hit for one person must never make a blurry scan look clear for another.
   - A profile whose only hits are free-from claims is `matchesFound(notice)`, never `noMatchesFound`.
   - The top banner is the worst per-profile state.
3. **Union, never subtract.** Merging more text (another frame, another panel, a fuzzy pass) can add findings but must never remove one. This is a tested property.
4. **Over-flag.** Prefer a false alarm to a missed allergen. Substring and fuzzy matching are used on purpose.
5. **Never suppress on a label claim.** "Dairy free" or "nut free" on a pack does not clear anything. A term inside a free-from claim is shown as a low-level notice, and any real occurrence elsewhere is still a full match.
6. **Show the evidence.** Every match shows the matched text and, when known, the line it came from, so the person checks the real label, not the app.
7. **Worst first.** Alerts are ordered by level, then by profile name. Every affected person is listed.
8. **No data leaves the device.** No accounts, no analytics, no network calls in the scan path.

## 2. Data model

- **Profile**: name plus a list of entries.
- **Entry**: an allergen id (or `custom:<text>`), a `Sensitivity`, and an optional `strictAdvisory` flag.
- **Sensitivity**: `severe`, `moderate`, `mild`, `intolerance`.
- **Allergen**: id, display name, terms by kind (`name`, `derivative`, `ambiguous`) and language, and an `inherits` list. An entry for `tree_nut` matches every nut it inherits; `lactose` inherits `milk`; `gluten` inherits wheat, barley and rye.

## 3. Evidence tiers (strongest first)

| Tier | Meaning | Example |
|---|---|---|
| `direct` | the allergen is named | milk, peanut |
| `derivative` | a known ingredient made from it | casein, whey |
| `ambiguous` | may be made from it | hydrolyzed protein, lecithin |
| `advisory` | cross-contact warning | "may contain", "made in a facility with" |
| `freeClaim` | appears inside a free-from claim | "peanut free" |

A free-from claim is scoped tightly: the single term directly before "free" or "frei" ("lactose-free"), or the list after "free from", "free of", "without" and similar, which stops at any digit, bracket, colon, sentence end, or the words contain, may and ingredients. "Fat free milk" still matches milk. "Lactose-free milk" still matches milk. "Dairy-free creamer ... sodium caseinate" still matches caseinate.

An occurrence is `advisory` only when it follows an advisory phrase in the same sentence, within 160 characters, with no sentence end, `contains` statement or ingredients header in between. Anything else keeps its base tier.

## 4. Alert levels

| Sensitivity | direct / derivative | ambiguous | advisory | freeClaim |
|---|---|---|---|---|
| severe | CRITICAL | CRITICAL | CRITICAL | notice |
| moderate | WARNING | WARNING | CAUTION | notice |
| mild | CAUTION | NOTICE | NOTICE | notice |
| intolerance | CAUTION | NOTICE | NOTICE | notice |

`strictAdvisory` treats advisory hits as direct for that entry. Fuzzy (OCR-misread) hits keep the level of the term they resemble and are labelled "possible misread".

Messages follow the pattern `CRITICAL - SEVERE ALLERGEN FOR <NAME>`, `Warning - moderate allergen for <name>`, `Caution - mild allergy or intolerance for <name>`.

## 5. Read quality

A scan is `reliable` only if every capture passes:

- enough text (at least 15 letters),
- confidence-weighted average at least 0.6 and under 30% of characters in lines below 0.5,
- at least half of the non-space characters are letters or digits (guards against garbage from an unsupported script),
- and at least one capture contains an ingredients header (in any supported language).

The thresholds are configuration (`ReadQualityConfig`), not constants. They are first guesses and must be calibrated on real photos, because Vision's confidence values are coarse.

A capture that only lacks an ingredients header (for example the nutrition panel) does not make the scan unreliable if another capture has one. A blurry or empty capture always does.

## 6. Layout and language resilience

- No language detection. All languages' terms are matched at once.
- Matching does not depend on position. Headers only affect read quality.
- Text is normalised: Unicode compatibility folding, case folding, accent stripping (Latin only, so Japanese voiced marks survive), hyphenated line wraps repaired (matched both ways), E-numbers canonicalised.
- **Substring is the default.** It catches compounds (buttermilk, Weizenmehl, Haselnüsse) and run-together OCR output (peanutbutter). A term is whole-word only when marked `=` in the data because the substring is too noisy (nut, egg, oat, corn, rye, cod). Each `=` term needs a golden test. A leading `!` excludes a term from fuzzy matching.
- **OCR-confusable fold** applied to both text and terms before matching, one character for one: 0→o, 1→l, i→l, 5→s. So "m1lk", "mi1k" and "mllk" all hit milk, including the short allergens fuzzy matching cannot reach.
- Fuzzy matching (edit distance 1, or 2 for long terms) on single-word terms of 6 or more letters.
- **Exclusions** are narrow, documented phrases where a term is known not to mean the allergen (cocoa butter, coconut milk, buckwheat for wheat). An exclusion removes only the one overlapping hit.
- **Inheritance is two-way in effect.** A milk entry matches "lactose" because lactose is a milk derivative term. A lactose or dairy-intolerance entry matches "milk" because it inherits milk's terms. Both directions are tested.
- Non-English term lists are a first draft and need native-speaker review. See `CONTRIBUTING.md`.

## 7. Licence and signing

MIT for code and data. Apple team ID `R9ACZFAZ2U`, automatic signing, bundle id `me.arrhen.ReactCheck`.

## 8. Out of scope for v1

Barcode and product lookup, on-device VLM, cloud anything, accounts, scan history, Android.

## 9. Not a medical device

React Check does not diagnose, treat or promise safety. Labels can be wrong, change, or omit cross-contact. Onboarding requires acknowledgement of this and every result screen repeats it.

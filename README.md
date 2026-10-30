# React Check

A free, open-source iOS app that reads a food label with the camera and flags anything matching the allergies and intolerances of the people you cook for. It is an aid. It never replaces reading the label.

- Profiles for each person, with severity (severe, moderate, mild, intolerance).
- On-device OCR (Apple Vision). No account, no network, no tracking.
- Fails safe: a blurry or incomplete read is reported as "couldn't read this reliably", never as "no matches".
- Matches names, derivatives (casein, whey), "may contain" and facility statements, and common non-English labels.

See [SPEC.md](SPEC.md) for the safety rules and matching design.

## Layout

| Path | What |
|---|---|
| `Sources/ReactCheckCore` | Matcher, data model, allergen data (`Resources/*.json`). All safety logic. |
| `Tests/ReactCheckCoreTests` | Unit tests and the golden label cases (`Golden/golden.json`). |
| `App` | SwiftUI app. |
| `project.yml` | XcodeGen spec. Run `xcodegen generate` to create the project. |

## Build and test

```bash
swift test
xcodegen generate && open ReactCheck.xcodeproj
```

## Licence

MIT. Free today, with no plans to change that. Optional donations via GitHub Sponsors never unlock features or change how matching works.

# bot-brain contract v1 — golden fixtures

Three JSON shapes cross the boundary between `modules/mod-bot-brain` (C++, in the worldserver)
and `services/bot-brain` (Go, out of process). Each is written by one side and read by the
other:

| fixture | written by | read by |
|---|---|---|
| `golden/plan-request.json` | C++ `EncodePlanRequest` | Go `DecodePlanRequest` |
| `golden/plan-response.json` | Go, `PlanResponse` | C++ `DecodePlanResponse` |
| `golden/contract-info.json` | Go, `ContractInfo` | C++ `DecodeContractInfo` |

**Each fixture is checked by the side that must *read* it.** The Go test decodes
`plan-request.json` and asserts the parsed values; the C++ tests decode the other two and assert
theirs. Neither side checks its own output against a golden, because that would only prove it
agrees with itself.

## Why these exist

The wire format is defined **twice, by hand, in two languages**. `contract/version.go` declares
`VersionMajor`/`VersionMinor`; `BotBrainWire.h` declares `kContractMajor`/`kContractMinor` with
the comment *"Must track services/bot-brain/contract/version.go"* — and until these fixtures,
nothing enforced any of it. Both suites could stay green while the two definitions drifted
apart, and the first symptom would be every bot silently receiving no intent.

`BotBrainWire.cpp:242` carries the comment:

> `// "pois". Not "poi". This name has been got wrong before.`

That is the argument for this directory. A field name, a nesting level or a scale (percentages
are 0..100, not 0..1) can change on one side and pass its own tests.

## Rules

- **Decoding is the check, not byte equality.** The two sides use different JSON writers, so key
  order and float formatting differ legitimately. Comparing bytes would fail for reasons that do
  not matter and would train people to regenerate the fixture instead of thinking.
- **Changing a fixture is changing the contract.** If a fixture must change to make a test pass,
  that is a wire-format change: bump `VersionMinor` for an additive one, `VersionMajor` for
  anything a peer could misread, and update **both** declarations.
- **Fixtures are deliberately complete**, including optional fields, so a side that silently
  stops emitting one is caught. Absent-vs-zero is load-bearing here: `power_pct`,
  `durability_pct` and `distance_yards` are pointers in Go and value+flag in C++, and a missing
  key must stay distinguishable from a zero.

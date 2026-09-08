# personality contract v1 — trait catalog and pools

Both files here are **generated**. The source of truth is
`docs/contracts/personality-context-contract-v1.md`, where the catalog lives as German markdown
tables. Edit the markdown, then regenerate:

```sh
python ops/contracts/extract-personality-catalog.py          # rewrite
python ops/contracts/extract-personality-catalog.py --check   # fail if stale
```

| file | holds | consumed by |
|---|---|---|
| `traits.json` | 124 traits: key, German label, Ollama instruction, the section 8 subsection it came from | the prompt builder / LLM bridge |
| `pools.json` | the section 5, 5.1, 6 and 7 pools plus the section 4 quotas and strengths and the section 9.2 conflicts | provisioning, and any second implementation of the contract |

The same parse also writes `modules/mod-bot-brain/src/PersonalityCatalog.h`, which is the pools
again as ASCII-only C++ tables. That duplication is deliberate and is why it is generated: the
selection policy (`PersonalityPolicy.h`) is a pure decision function that has to be linkable into
a unit test with no parser, no fixture path and no encoding flags, while the labels and
instructions — the parts that are actually German — never reach it. One parse, three outputs,
nothing hand-maintained.

## What the markdown does not contain

Two things the extractor supplies itself, and which therefore live in the script rather than in
the contract:

- **canonical English keys** for races, variants, classes and professions. The tables name them
  in German (`Zwerg`, `Krieger`, `Schmiedekunst`); the JSON example in section 12 shows the wire
  form is `dwarf`, `warrior`, `blacksmithing`.
- **profession skill ids**. Section 14 item 4 leaves these pending a check against the actual
  server, so an unverified profession carries `skill_id: 0` and can only be matched by key.
  `survival` and `gardening` are Turtle-specific and genuinely unknown; `jewelcrafting` is 755
  upstream, but section 7 doubts this server carries the profession at all and keeps it, with
  `gardening`, `enabled: false`.

## What checks what

The extractor refuses to write when a pool references a trait key that section 8 does not define,
or when a pool is not the size the contract states (6 race, 6 variant, 5 class, 3 profession).
`modules/mod-bot-brain/t/personality_policy_tests.cpp` asserts the same two properties against the
generated header, so a hand-edit of either output fails a test rather than reaching a bot.

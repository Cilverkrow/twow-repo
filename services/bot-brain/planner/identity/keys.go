package identity

// Personality trait keys, and the only place they mean anything to a bot that
// is not talking.
//
// The personality contract (docs/contracts/personality-context-contract-v1.md)
// assigns each bot a set of trait keys from race, class and profession pools.
// Until now they reached exactly one place: a line of prompt text. With
// inference off -- which is the default, and the configuration this service is
// designed to survive in -- a bot's personality had no effect on anything it
// did. Two bots with opposite personalities picked the same destination.
//
// This maps the handful of keys that are genuinely about *going places* onto
// the one numeric trait the rule planner already understands. It is deliberately
// a handful: of the contract's 124 keys, most describe how a bot talks, and
// inventing a movement meaning for them would be making up data.
//
// The readings below come from the contract's own §8 definitions, not from the
// English words, because three of those disagree:
//
//   - `fearless` sounds like the boldest key in the vocabulary. §8 defines it as
//     reacting calmly to unpleasant CRAFT WORK ("unangenehme Handwerksarbeit").
//     It says nothing about danger or distance, and it is not mapped.
//   - `wilderness_savvy` sounds like a bot at home in the wilds. §8 has it
//     preferring CAUTIOUS progress and only KNOWN locations ("nutzt nur bekannte
//     Ortsinformationen"), so it lowers boldness rather than raising it.
//   - `reserved` and `patient` are about disclosure and social pacing. Neither
//     is a travel trait, and neither is mapped.

// keyBoldness is the per-key adjustment to [Traits.Boldness].
//
// Small on purpose. A bot holds several keys at once and they accumulate, so a
// large step would let three mild traits pin a bot to the edge of the band and
// erase the derived identity underneath. At 0.08 a bot needs an unusually
// one-sided personality to move even a third of the way to a bound.
var keyBoldness = map[string]float64{
	// Bolder: each of these is defined in terms of unknown places, open ground,
	// or preferring the braver plan.
	"risk_taking":   +BoldnessKeyStep, // "bevorzugt gelegentlich den mutigeren Plan"
	"curious":       +BoldnessKeyStep, // "interessiert sich für unbekannte Orte"
	"outdoorsy":     +BoldnessKeyStep, // "bevorzugt offene Landschaft und Bewegung"
	"free_spirited": +BoldnessKeyStep, // "bevorzugt persönliche Freiheit und offene Wege"

	// More cautious: defined in terms of checking first, asking for
	// confirmation, or sticking to what is already known.
	"wary":             -BoldnessKeyStep, // "prüft unbekannte Situationen erst"
	"mistrustful":      -BoldnessKeyStep, // "bittet bei riskanten Plänen um Bestätigung"
	"wilderness_savvy": -BoldnessKeyStep, // "vorsichtiges Vorgehen ... nur bekannte Ortsinformationen"
}

// BoldnessKeyStep is how far one trait key moves a bot's travel willingness.
const BoldnessKeyStep = 0.08

// ApplyKeys folds a bot's personality keys into its derived traits.
//
// Unknown keys are ignored rather than guessed at, for the same reason
// [Traits.apply] drops an unknown stored trait: the pools are an unconstrained
// vocabulary, most of it about conversation, and a key this package has no
// opinion on must produce no opinion.
//
// KNOWN GAP, and it only bites once keys are actually assigned: the first time
// memory.Learner writes a boldness row it steps from the DERIVED value
// (cmd/bot-brain/main.go wires Derived to identity.Derive(uuid).Boldness), which
// does not include these keys. So a bold bot's first learned write silently
// drops its personality. Closing it means giving the Learner access to each
// bot's key set, which lives on the snapshot rather than in the store -- shared
// mutable state that is not worth building before anything assigns keys.
//
// A bot that has LEARNED is left alone. Stored traits come from
// memory.Learner watching what actually happened to this bot, and that is
// better evidence about how far it should range than the personality it was
// born with. Letting keys shift a learned value would also re-apply the same
// offset on every tick, walking the bot to a bound over a few minutes.
func ApplyKeys(t Traits, keys []string) Traits {
	if t.Learned || len(keys) == 0 {
		return t
	}
	adj := 0.0
	for _, k := range keys {
		adj += keyBoldness[k] // absent keys contribute 0
	}
	if adj == 0 {
		return t
	}
	t.Boldness = clamp(t.Boldness+adj, boldnessMin, boldnessMax)
	return t
}

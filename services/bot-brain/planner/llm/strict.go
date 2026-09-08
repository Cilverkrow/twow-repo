package llm

import (
	"encoding/json"
)

// strictIntent decodes one intent object the model produced, refusing anything
// that is not exactly the shape we asked for.
//
// Why this is not plain json.Unmarshal, which is what it replaced: encoding/json
// accepts three things silently that all mean the model misunderstood us.
//
//   - UNKNOWN FIELDS are dropped. `{"bot":0,"kind":"travel_to","target":"p1"}`
//     decodes cleanly with no target, so a model that renamed poi_id produces a
//     travel intent to nowhere rather than an error anyone can see.
//   - NAMES MATCH CASE-INSENSITIVELY. `"KIND"` fills Kind. That is a Go
//     convenience, not a contract, and it means a model can drift away from the
//     published schema without anything noticing.
//   - DUPLICATE KEYS take the last value. `{"bot":0,"bot":3}` plans for a bot
//     nobody looked at, quietly.
//
// [exactObject] rejects all three, and was written for the PoC decoder. This is
// the half of that decoder worth having in production: it applies to the object
// WE define, rather than to the provider envelope, which varies legitimately.
//
// Returning false drops one intent. The caller keeps the rest, so a single
// malformed entry costs one bot its plan rather than the whole batch.
func strictIntent(raw json.RawMessage) (modelIntent, bool) {
	fields, err := exactObject(raw,
		[]string{"bot", "kind"},
		[]string{"poi_id", "quest_id", "why", "certainty"})
	if err != nil {
		return modelIntent{}, false
	}

	var mi modelIntent
	if json.Unmarshal(fields["bot"], &mi.Bot) != nil {
		return modelIntent{}, false
	}
	if json.Unmarshal(fields["kind"], &mi.Kind) != nil {
		return modelIntent{}, false
	}
	// The optional four. Each is decoded only when present, so an absent field
	// keeps its zero value and a present-but-wrong-typed one drops the intent
	// rather than silently becoming zero -- "certainty": "high" must not read as
	// certainty 0.
	for key, into := range map[string]any{
		"poi_id":    &mi.POIID,
		"quest_id":  &mi.QuestID,
		"why":       &mi.Why,
		"certainty": &mi.Certainty,
	} {
		if v, ok := fields[key]; ok {
			if json.Unmarshal(v, into) != nil {
				return modelIntent{}, false
			}
		}
	}
	return mi, true
}

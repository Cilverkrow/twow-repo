package llm

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"unicode/utf8"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
)

// exactObject rejects duplicate, unknown, differently cased, and null fields.
// encoding/json's struct decoder alone accepts several of those forms.
func exactObject(raw []byte, required, optional []string) (map[string]json.RawMessage, error) {
	if !utf8.Valid(raw) {
		return nil, errors.New("poc: invalid UTF-8")
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	t, err := d.Token()
	if err != nil || t != json.Delim('{') {
		return nil, errors.New("poc: expected object")
	}
	allowed := make(map[string]bool)
	for _, k := range append(append([]string{}, required...), optional...) {
		allowed[k] = true
	}
	fields := make(map[string]json.RawMessage)
	for d.More() {
		t, err := d.Token()
		if err != nil {
			return nil, err
		}
		k, ok := t.(string)
		if !ok || !allowed[k] || fields[k] != nil {
			return nil, errors.New("poc: invalid field")
		}
		var value json.RawMessage
		if err := d.Decode(&value); err != nil {
			return nil, err
		}
		if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return nil, errors.New("poc: null field")
		}
		fields[k] = value
	}
	if _, err := d.Token(); err != nil {
		return nil, err
	}
	if _, err := d.Token(); err != io.EOF {
		return nil, errors.New("poc: trailing content")
	}
	for _, k := range required {
		if fields[k] == nil {
			return nil, errors.New("poc: missing field")
		}
	}
	return fields, nil
}

// The PoC accepts one explicitly specified chat-completions projection, not
// prose, fences, first-object extraction, tool calls, or multiple choices.
func pocContent(raw []byte) (string, error) {
	fields, err := exactObject(raw, []string{"choices"}, []string{"usage"})
	if err != nil {
		return "", err
	}
	var choices []json.RawMessage
	if err := json.Unmarshal(fields["choices"], &choices); err != nil || len(choices) != 1 {
		return "", errors.New("poc: expected one choice")
	}
	choice, err := exactObject(choices[0], []string{"message"}, nil)
	if err != nil {
		return "", err
	}
	message, err := exactObject(choice["message"], []string{"role", "content"}, nil)
	if err != nil {
		return "", err
	}
	var role, content string
	if json.Unmarshal(message["role"], &role) != nil || role != "assistant" || json.Unmarshal(message["content"], &content) != nil {
		return "", errors.New("poc: invalid message")
	}
	return content, nil
}

func pocDecode(content string, snapshot contract.Snapshot, clean contract.Snapshot, expiry int64) (contract.Intent, error) {
	fail := func() (contract.Intent, error) { return contract.Intent{}, errors.New("poc: invalid proposal") }
	root, err := exactObject([]byte(content), []string{"intents"}, nil)
	if err != nil {
		return fail()
	}
	var intents []json.RawMessage
	if json.Unmarshal(root["intents"], &intents) != nil || len(intents) != 1 {
		return fail()
	}
	fields, err := exactObject(intents[0], []string{"bot", "kind", "certainty"}, []string{"poi_id"})
	if err != nil {
		return fail()
	}
	var mi modelIntent
	if json.Unmarshal(intents[0], &mi) != nil || mi.Bot != 0 || mi.Certainty < 0 || mi.Certainty > 1 {
		return fail()
	}
	switch mi.Kind {
	case "idle", "rest":
		if fields["poi_id"] != nil {
			return fail()
		}
	case "travel_to":
		if fields["poi_id"] == nil || mi.POIID == "" || snapshot.Vit.IsDead || snapshot.Vit.InCombat || snapshot.Pos.InstanceID != 0 || (snapshot.Around.GroupSize > 1 && !snapshot.Around.IsGroupLeader) {
			return fail()
		}
	default:
		return fail() // smaller PoC vocabulary, not a change to the wire
	}
	// Reuse the existing validator without its permissive normalization: kind,
	// certainty and all fields have already passed the stricter checks above.
	clean.Bot = snapshot.Bot
	in, ok := validate(mi, &clean)
	if !ok {
		return fail()
	}
	if in.Travel != nil {
		found := false
		for i, poi := range clean.POIs {
			if poi.ID == in.Travel.POIID {
				in.Travel.POIID = snapshot.POIs[i].ID
				found = true
				break
			}
		}
		if !found {
			return fail()
		}
	}
	in.ExpiresAtMS = expiry
	in.Source = "llm-poc"
	in.Rationale = "" // free model text is neither a log nor a delivery channel
	if in.Validate() != nil {
		return fail()
	}
	return in, nil
}

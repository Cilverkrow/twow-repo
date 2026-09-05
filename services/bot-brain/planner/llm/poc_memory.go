package llm

import (
	"context"
	"errors"
	"fmt"
	"math"
	"regexp"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
)

// MemoryReader is a request-scoped read boundary, not a database schema.
// A future MariaDB VECTOR adapter must use the stored UUID, respect ctx and
// limit, and return only that bot's records. There is deliberately no SQL or
// embedding model invented here: ADR-0039 does not specify them yet.
type MemoryReader interface {
	Retrieve(ctx context.Context, storedUUID string, limit int) ([]MemoryObservation, error)
}

// MemoryObservation is the deliberately small PoC projection of an observation.
// No free-form conversation, name, prompt, or identifier is sent to inference.
// POIID is resolved against THIS snapshot and replaced with a local alias.
// This type is not a persistence or embedding contract.
type MemoryObservation struct {
	BotUUID string
	POIID   string
	Outcome string // exactly completed, rejected, or failed
}

const pocMemoryLimit = 8
const pocPOILimit = 32

var storedUUIDPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

type promptMemory struct {
	Destination string `json:"destination"`
	Outcome     string `json:"outcome"`
}

// pocSnapshot uses the existing egress formatter, but gives it only typed,
// bounded data. Even arbitrary server POI IDs become request-local aliases.
// Neither caller-owned slices nor the real BotID are modified.
func pocSnapshot(s contract.Snapshot) (contract.Snapshot, map[string]string, error) {
	if err := s.Validate(); err != nil {
		return contract.Snapshot{}, nil, errors.New("poc: invalid snapshot")
	}
	if math.IsNaN(s.Vit.HealthPct) || math.IsInf(s.Vit.HealthPct, 0) || len(s.POIs) > pocPOILimit || (s.Bot.UUID != "" && !storedUUIDPattern.MatchString(s.Bot.UUID)) {
		return contract.Snapshot{}, nil, errors.New("poc: invalid identity or POI bound")
	}
	clean := contract.Snapshot{
		Char: contract.Character{Level: s.Char.Level, Class: s.Char.Class, FreeBagSlots: s.Char.FreeBagSlots},
		Vit:  contract.Vitals{HealthPct: s.Vit.HealthPct, IsResting: s.Vit.IsResting},
	}
	if s.Char.Faction != "alliance" && s.Char.Faction != "horde" {
		return contract.Snapshot{}, nil, errors.New("poc: invalid faction")
	}
	clean.Char.Faction = s.Char.Faction
	aliases := make(map[string]string, len(s.POIs))
	for i, poi := range s.POIs {
		if poi.ID == "" || len(poi.ID) > 256 || !poi.Pos.SameMap(s.Pos) {
			return contract.Snapshot{}, nil, errors.New("poc: invalid POI")
		}
		if _, exists := aliases[poi.ID]; exists {
			return contract.Snapshot{}, nil, errors.New("poc: duplicate POI")
		}
		switch poi.Kind {
		case "quest_objective", "quest_turnin", "quest_giver", "vendor", "repair", "trainer", "innkeeper", "mailbox", "grind_area", "flight_master", "graveyard":
		default:
			return contract.Snapshot{}, nil, errors.New("poc: unsupported POI kind")
		}
		alias := fmt.Sprintf("p%d", i)
		aliases[poi.ID] = alias
		clean.POIs = append(clean.POIs, contract.PointOfInterest{ID: alias, Kind: poi.Kind})
	}
	return clean, aliases, nil
}

func (p *PoC) memories(ctx context.Context, uuid string, aliases map[string]string) ([]promptMemory, error) {
	if uuid == "" || p.reader == nil {
		return []promptMemory{}, nil // no identity: stateless, never derive one
	}
	rows, err := p.reader.Retrieve(ctx, uuid, pocMemoryLimit)
	if err != nil {
		return nil, errors.New("poc: memory unavailable") // never expose store errors
	}
	if len(rows) > pocMemoryLimit {
		return nil, errors.New("poc: memory bound exceeded")
	}
	out := make([]promptMemory, 0, len(rows))
	for _, row := range rows {
		if row.BotUUID != uuid {
			return nil, errors.New("poc: memory identity mismatch")
		}
		switch row.Outcome {
		case "completed", "rejected", "failed":
		default:
			return nil, errors.New("poc: unsupported memory observation")
		}
		alias, exists := aliases[row.POIID]
		if !exists {
			continue // old destinations are not current game facts or targets
		}
		out = append(out, promptMemory{Destination: alias, Outcome: row.Outcome})
	}
	return out, nil
}

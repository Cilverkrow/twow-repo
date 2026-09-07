package mysqlstore

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/memory"
)

// Record writes one observation and prunes that bot's history to
// [memory.DefaultRetention].
//
// Pruning here rather than in a sweep job: retention that depends on a scheduled
// task is retention that silently stops when the task does, and this table only
// grows through this one function. The cost is a second statement per write,
// which is affordable because writes are already off the request path.
func (s *Store) Record(ctx context.Context, uuid string, o memory.Observation) error {
	if s == nil || s.db == nil {
		return fmt.Errorf("mysqlstore: no database")
	}
	if uuid == "" {
		return fmt.Errorf("mysqlstore: empty uuid")
	}

	observedAt := o.ObservedAtMS
	if observedAt == 0 {
		// The worldserver stamps this; zero means it did not, and a row with no
		// age is worse than useless -- retention would keep it forever and
		// "recent" would never include it.
		observedAt = time.Now().UnixMilli()
	}

	const insert = "INSERT INTO `bot_observation` " +
		"(`bot_uuid`, `kind`, `poi_id`, `result`, `reason`, `observed_at`) VALUES (?, ?, ?, ?, ?, ?)"
	if _, err := s.db.ExecContext(ctx, insert,
		uuid, clip(o.Kind, 32), clip(o.POIID, 64), clip(o.Result, 16), clip(o.Reason, 32), observedAt,
	); err != nil {
		// A foreign key violation is the expected error, not a broken one: the
		// bot's identity row is minted asynchronously, so an outcome can arrive
		// before the identity it belongs to exists. Reported, never retried --
		// the next outcome for that bot will land once the mint completes.
		return fmt.Errorf("mysqlstore: record observation: %w", err)
	}

	// Keep the newest N. The subquery is needed because MySQL will not DELETE
	// from a table it is also selecting from directly.
	const prune = "DELETE FROM `bot_observation` WHERE `bot_uuid` = ? AND `id` NOT IN " +
		"(SELECT `id` FROM (SELECT `id` FROM `bot_observation` WHERE `bot_uuid` = ? " +
		"ORDER BY `observed_at` DESC, `id` DESC LIMIT ?) AS keep)"
	if _, err := s.db.ExecContext(ctx, prune, uuid, uuid, memory.DefaultRetention); err != nil {
		// Pruning is housekeeping. Failing it must not fail the write that
		// already succeeded, or a full table would start losing new history to
		// protect itself from old history.
		return nil
	}
	return nil
}

// Recent returns each bot's newest observations.
//
// One query for the whole batch. A batch may carry 2048 bots, and per-bot round
// trips inside a planning deadline would spend it before the plan did.
func (s *Store) Recent(ctx context.Context, uuids []string, perBot int) (map[string][]memory.Observation, error) {
	out := make(map[string][]memory.Observation)
	if s == nil || s.db == nil || len(uuids) == 0 || perBot <= 0 {
		return out, nil
	}

	seen := make(map[string]bool, len(uuids))
	args := make([]any, 0, len(uuids))
	for _, u := range uuids {
		if u == "" || seen[u] {
			continue
		}
		seen[u] = true
		args = append(args, u)
	}
	if len(args) == 0 {
		return out, nil
	}

	// Deliberately NOT a per-bot LIMIT via window functions: MariaDB has them,
	// but this runs against whatever the deployment actually has, and the row
	// count is already bounded -- retention caps each bot at DefaultRetention,
	// so the worst case is bounded by the batch size times that constant. The
	// per-bot cut happens below, where it costs nothing.
	query := "SELECT `bot_uuid`, `kind`, `poi_id`, `result`, `reason`, `observed_at` " +
		"FROM `bot_observation` WHERE `bot_uuid` IN (" +
		strings.TrimSuffix(strings.Repeat("?,", len(args)), ",") + ") " +
		"ORDER BY `bot_uuid`, `observed_at` DESC, `id` DESC"

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("mysqlstore: recent observations: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var uuid string
		var o memory.Observation
		if err := rows.Scan(&uuid, &o.Kind, &o.POIID, &o.Result, &o.Reason, &o.ObservedAtMS); err != nil {
			return nil, fmt.Errorf("mysqlstore: scan observation: %w", err)
		}
		if len(out[uuid]) >= perBot {
			continue
		}
		out[uuid] = append(out[uuid], o)
	}
	if err := rows.Err(); err != nil {
		// Checked rather than assumed: a truncated result would look like a set
		// of bots that had never failed anywhere, which is indistinguishable
		// from success and would quietly un-learn every lesson.
		return nil, fmt.Errorf("mysqlstore: observation rows: %w", err)
	}
	return out, nil
}

// clip bounds a value to its column width.
//
// The strings come off the wire from the worldserver, and "it is only ever a
// short machine code" is an assumption about a remote process rather than a
// property of this function. Truncating loses a little detail; letting the
// driver reject the row loses the observation entirely.
func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

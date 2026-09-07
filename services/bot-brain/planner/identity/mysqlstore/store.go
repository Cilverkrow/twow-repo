// Package mysqlstore reads and writes bot traits in cv_brain.
//
// This is the bot-brain service's first database dependency, and it is worth
// saying why it earns its place: traits that change need somewhere to change,
// and memory retrieval -- the reason ADR-0039 mints a stable UUID at all -- is a
// query formed at planning time. Pushing that state over the wire instead would
// mean the worldserver sending, every tick and for every bot in a batch of up to
// 2048, everything the planner MIGHT need, without knowing what the plan will
// be.
//
// The service still runs without it. No DSN configured means no store, and the
// planner falls back to derived traits.
package mysqlstore

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

// Store reads and writes cv_brain.bot_trait.
type Store struct {
	db *sql.DB
}

// Open connects to cv_brain. The DSN is the go-sql-driver form, e.g.
//
//	brain:secret@tcp(db:3306)/cv_brain?parseTime=false&timeout=5s
//
// Open does not ping. A brain that refuses to start because the trait store is
// unreachable would be a brain that cannot plan at all for want of a value it
// has a safe default for -- the exact trade ADR-0012 makes in the other
// direction for admission, and for the opposite reason: there is no safe way to
// guess a plan, but there is a safe way to guess a trait.
func Open(dsn string) (*Store, error) {
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, fmt.Errorf("mysqlstore: open: %w", err)
	}

	// Bounded on purpose. This pool serves one planning batch at a time against
	// a database that is also carrying the worldserver's own traffic; an
	// unbounded pool turns a slow query into a connection storm on the process
	// the game is actually running on.
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(2)
	db.SetConnMaxLifetime(30 * time.Minute)

	return &Store{db: db}, nil
}

// Close releases the pool.
func (s *Store) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
}

// Ping reports whether the store is reachable. For the readiness endpoint and
// for startup logging -- never as a gate on planning.
func (s *Store) Ping(ctx context.Context) error {
	if s == nil || s.db == nil {
		return fmt.Errorf("mysqlstore: no database")
	}
	return s.db.PingContext(ctx)
}

// Load returns the stored traits for the given UUIDs.
//
// One query for the whole batch rather than one per bot: a batch may carry 2048
// bots, and 2048 round trips inside a planning tick would blow the deadline on
// its own.
func (s *Store) Load(ctx context.Context, uuids []string) (map[string]map[string]float64, error) {
	out := make(map[string]map[string]float64)
	if s == nil || s.db == nil || len(uuids) == 0 {
		return out, nil
	}

	// Deduplicate first. A batch can legitimately carry the same bot twice, and
	// the IN list is the one place where that turns into wasted query text.
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

	// Placeholders rather than interpolation. The UUIDs arrive over the wire
	// from the worldserver, and "it is only ever a UUID" is an assumption about
	// a remote process, not a property of this function.
	query := "SELECT `bot_uuid`, `trait`, `value` FROM `bot_trait` WHERE `bot_uuid` IN (" +
		strings.TrimSuffix(strings.Repeat("?,", len(args)), ",") + ")"

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("mysqlstore: load: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var uuid, trait string
		var value float64
		if err := rows.Scan(&uuid, &trait, &value); err != nil {
			return nil, fmt.Errorf("mysqlstore: scan: %w", err)
		}
		if out[uuid] == nil {
			out[uuid] = make(map[string]float64, 2)
		}
		out[uuid][trait] = value
	}
	if err := rows.Err(); err != nil {
		// Checked rather than assumed: a partial result here would look like a
		// set of bots that had never changed, which is indistinguishable from
		// success and would quietly revert their personalities.
		return nil, fmt.Errorf("mysqlstore: rows: %w", err)
	}
	return out, nil
}

// Set writes one trait for one bot, recording why.
//
// Upsert rather than insert-or-update in two statements: two bots' outcomes can
// be applied concurrently, and the read-then-write form would lose one of them
// with no sign that it happened.
//
// `reason` is not decoration. When a bot turns out timid the question is always
// what happened to it, and a trait system that cannot answer that is one nobody
// can debug.
func (s *Store) Set(ctx context.Context, uuid, trait string, value float64, reason string) error {
	if s == nil || s.db == nil {
		return fmt.Errorf("mysqlstore: no database")
	}
	if uuid == "" {
		return fmt.Errorf("mysqlstore: empty uuid")
	}
	if trait == "" {
		return fmt.Errorf("mysqlstore: empty trait")
	}
	if len(reason) > 255 {
		reason = reason[:255]
	}

	const q = "INSERT INTO `bot_trait` (`bot_uuid`, `trait`, `value`, `updated_at`, `reason`) " +
		"VALUES (?, ?, ?, ?, ?) " +
		"ON DUPLICATE KEY UPDATE `value` = VALUES(`value`), " +
		"`updated_at` = VALUES(`updated_at`), `reason` = VALUES(`reason`)"

	// Unix milliseconds, matching bot_identity.first_seen and the wire's
	// observed_at_ms rather than SQL NOW(), so ages stay comparable.
	_, err := s.db.ExecContext(ctx, q, uuid, trait, value, time.Now().UnixMilli(), reason)
	if err != nil {
		return fmt.Errorf("mysqlstore: set %s/%s: %w", uuid, trait, err)
	}
	return nil
}

#!/usr/bin/env bash
# Verify every selected migration against the actual raw-byte ledger identity.
# Caller supplies an explicitly selected disposable DB and client credentials.
set -euo pipefail
: "${DB_HOST:?}" "${DB_PORT:?}"
state=${BOOTSTRAP_STATE:-/state}
sql() { mariadb -h "$DB_HOST" -P "$DB_PORT" -uroot -NB "$@"; }
sql tw_world -e 'SELECT entry, effectBonusCoefficient1, effectBonusCoefficient2,
    effectBonusCoefficient3, minTargetLevel, customFlags FROM spell_extra LIMIT 0;'
test "$(sql tw_world -e 'SELECT COUNT(*) FROM spell_extra')" -gt 0
for pair in 'world tw_world' 'character tw_char' 'logon tw_logon'; do
    read -r stream db <<< "$pair"
    count=0
    while IFS= read -r f; do
        name=$(basename "$f" .sql)
        if [ "${IMPORT_PLAYERBOTS:-ON}" != ON ] &&
            [ "$name" = 20260708055500_ai_playerbot_random_bots_index ]; then
            continue
        fi
        hash=$(sha1sum "$f" | cut -d' ' -f1 | tr 'a-f' 'A-F')
        test "$(sql "$db" -e "SELECT COUNT(*) FROM migrations WHERE Name='$name' AND BINARY Hash='$hash'")" = 1
        count=$((count + 1))
    done < "$state/$stream-inputs"
    test "$(sql "$db" -e 'SELECT COUNT(*) FROM migrations')" = "$count"
    printf '%s: %s exact migration identities verified\n' "$db" "$count"
done
echo 'BOOTSTRAP_COVERAGE=PASS'

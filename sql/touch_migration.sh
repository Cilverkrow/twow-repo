#!/usr/bin/env sh
# Create an empty, correctly named world migration.
#
# The name is what the auto-updater sorts on, so the UTC timestamp prefix is the
# whole point of running this instead of touching a file by hand.
DATE=$(date +%Y%m%d%H%M%S)
FPATH=database_updates/"$DATE"_world.sql

touch "$FPATH"

if [ -e "$FPATH" ]; then
	echo "File created"
else
	echo "FAILED to create file"
fi

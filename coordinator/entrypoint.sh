#!/bin/sh
# Run pending migrations against whichever backend the release was built for, then start the
# coordinator. DB_ADAPTER + DATABASE_URL + SECRET_KEY_BASE come from the environment.
set -e

/app/bin/coordinator eval "Coordinator.Release.migrate()"
exec /app/bin/coordinator start

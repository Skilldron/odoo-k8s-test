#!/bin/bash
# Prod image entrypoint: refuses to start without the required environment, then hands
# over to the official entrypoint (waits for PostgreSQL, starts Odoo). Nothing is
# rendered: Odoo 20 reads $ODOO_RC, then ODOO_<OPTION> and PG* from the environment,
# which take precedence over the file.
set -e

# Without them Odoo would start with admin_passwd = admin, and the official entrypoint
# would fall back to db / odoo / odoo, or Odoo would serve every database
: "${ODOO_ADMIN_PASSWD:?ODOO_ADMIN_PASSWD is required (Odoo master password)}"
: "${PGHOST:?PGHOST is required (PostgreSQL host)}"
: "${PGUSER:?PGUSER is required (PostgreSQL user)}"
: "${PGPASSWORD:?PGPASSWORD is required (PostgreSQL password)}"
: "${PGDATABASE:?PGDATABASE is required (database name)}"

exec /entrypoint.sh "$@"

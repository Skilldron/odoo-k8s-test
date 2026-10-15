#!/bin/bash
# Prod image entrypoint: builds the Odoo configuration from the environment, then hands
# over to the official entrypoint (waits for PostgreSQL, starts Odoo).
# - Default: renders $ODOO_CONFIG_TEMPLATE into $ODOO_RC (/tmp/odoo.conf).
# - Own configuration: mount it and point ODOO_RC to it, nothing is rendered.
set -e

if [ "$ODOO_RC" = /tmp/odoo.conf ]; then
    # Without them, the official entrypoint falls back to db / odoo / odoo
    : "${PGHOST:?PGHOST is required (PostgreSQL host)}"
    : "${PGUSER:?PGUSER is required (PostgreSQL user)}"
    : "${PGPASSWORD:?PGPASSWORD is required (PostgreSQL password)}"
    /opt/venv/bin/python /opt/odoo/render-config.py "$ODOO_CONFIG_TEMPLATE" "$ODOO_RC"
fi

exec /entrypoint.sh "$@"

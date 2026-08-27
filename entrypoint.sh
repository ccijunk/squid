#!/bin/sh
set -e

SQUID_CONF=/etc/squid/squid.conf
PID_FILE=/var/run/squid/squid.pid

# Initialize cache directories on first start (safe to re-run).
squid -z -f "$SQUID_CONF" 2>/dev/null || true

# `squid -z` leaves a stale pid file behind; remove it so the foreground
# instance can start cleanly.
rm -f "$PID_FILE"

# Run Squid in the foreground.
exec squid -N -f "$SQUID_CONF"

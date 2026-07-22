#!/bin/bash
# Family mruby VNC Desktop - Entrypoint
set -e

# Ensure runtime directory exists
mkdir -p /var/run/fmrb
chmod 1777 /var/run/fmrb

# Clean up stale VNC lock files
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1

# Start supervisord (manages VNC, noVNC, and fmruby processes)
exec /usr/bin/supervisord -n -c /etc/supervisor/conf.d/fmruby.conf

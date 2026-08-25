#!/bin/sh
# Put the OpenAI API key into a Tab5's /home/services.toml and restart the
# services host, so the tts service picks it up. The key never touches the
# repository: it is read from a local file (~/.openai_key by default) and
# written only to the device.
#
#   tools/fmrb_rd_tts_key.sh <IP> [keyfile]
#
# An existing api_key line is replaced (key rotation); otherwise a
# [tts.config] section is appended. The services host is restarted by pid,
# looked up from ps, so the running services come back with the new key.
set -eu

IP="${1:?usage: fmrb_rd_tts_key.sh <IP> [keyfile]}"
KEYFILE="${2:-$HOME/.openai_key}"
TOOLS="$(dirname "$0")"
TMP="$(mktemp /tmp/fmrb_services.XXXXXX.toml)"
trap 'rm -f "$TMP"' EXIT

[ -s "$KEYFILE" ] || { echo "error: key file $KEYFILE is missing or empty" >&2; exit 1; }

ruby "$TOOLS/fmrb_rd_fs.rb" "$IP" get /home/services.toml "$TMP" >/dev/null

ruby -e '
key = File.read(ARGV[1]).strip
t = File.read(ARGV[0])
if t.include?("api_key")
  # Replace the existing key, wherever it is, keeping the rest untouched.
  lines = t.lines.map { |l| l.start_with?("api_key") ? "api_key = \"#{key}\"\n" : l }
  t = lines.join
  puts "replaced api_key (#{key[0, 7]}...)"
else
  t = t.rstrip + "\n\n[tts.config]\napi_key = \"#{key}\"\n"
  puts "appended [tts.config] api_key (#{key[0, 7]}...)"
end
File.write(ARGV[0], t)
' "$TMP" "$KEYFILE"

ruby "$TOOLS/fmrb_rd_fs.rb" "$IP" put "$TMP" /home/services.toml >/dev/null
echo "written to /home/services.toml"

# Restart the services host so it re-reads the config. Its pid moves, so
# read it from ps rather than assuming.
PID="$(ruby "$TOOLS/fmrb_rd_ps.rb" "$IP" | awk '$2 == "Services" { print $1 }')"
if [ -n "$PID" ]; then
    ruby "$TOOLS/fmrb_rd_kill.rb" "$IP" "$PID" >/dev/null
fi
ruby "$TOOLS/fmrb_rd_launch.rb" "$IP" default/services

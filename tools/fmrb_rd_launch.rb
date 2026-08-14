#!/usr/bin/env ruby
# Start an app on a Tab5 by path, over WiFi.
# Usage: ruby fmrb_rd_launch.rb HOST /app/demo/mic_spectrum.app.rb
#
# The point of this is that the alternative -- menu, Launcher, scroll to the
# right row, Enter -- is four synthetic clicks that break whenever the list
# moves. Prints the new pid, which fmrb_rd_kill.rb takes.
require_relative "fmrb_rd_http"

host = ARGV[0]
path = ARGV[1]
unless host && path
  abort "usage: fmrb_rd_launch.rb HOST PATH\n" \
        "  e.g. fmrb_rd_launch.rb 192.168.10.13 /app/demo/mic_spectrum.app.rb"
end

status, body = FmrbRdHttp.request(host, "POST", "/app/launch?path=#{path}")
FmrbRdHttp.check_status(status, body)

if FmrbRdHttp.field(body, "ok") == "true"
  puts "launched #{path} as pid #{FmrbRdHttp.field(body, 'pid')}"
else
  abort "launch failed (HTTP #{status}): #{body}"
end

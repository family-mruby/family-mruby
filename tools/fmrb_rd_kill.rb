#!/usr/bin/env ruby
# Stop a running app on a Tab5 by pid, over WiFi.
# Usage: ruby fmrb_rd_kill.rb HOST PID
#
# User app pids only -- the firmware refuses the kernel, the host and the
# system app, so a slip cannot take the desktop down. fmrb_rd_ps.rb lists what
# is running.
require_relative "fmrb_rd_http"

host = ARGV[0]
pid = ARGV[1]
unless host && pid
  abort "usage: fmrb_rd_kill.rb HOST PID  (see fmrb_rd_ps.rb for pids)"
end

status, body = FmrbRdHttp.request(host, "POST", "/app/kill?pid=#{pid.to_i}")
FmrbRdHttp.check_status(status, body)

if FmrbRdHttp.field(body, "ok") == "true"
  puts "killed pid #{pid}"
else
  abort "kill failed (HTTP #{status}): #{body}"
end

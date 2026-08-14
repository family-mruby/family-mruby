#!/usr/bin/env ruby
# What is running on a Tab5, over WiFi.
# Usage: ruby fmrb_rd_ps.rb HOST
#
# Prints the pid, name and state of every process the firmware knows about --
# the kernel and system app included, so the picture is complete, even though
# only the user app pids can be killed from here.
require_relative "fmrb_rd_http"

host = ARGV[0] or abort "usage: fmrb_rd_ps.rb HOST"

status, body = FmrbRdHttp.request(host, "GET", "/app/list")
FmrbRdHttp.check_status(status, body)
abort "list failed (HTTP #{status}): #{body}" unless status == 200

apps = body.scan(/\{[^{}]*\}/)
if apps.empty?
  puts "no apps"
  exit
end

puts format("%-5s %-24s %s", "PID", "NAME", "STATE")
apps.each do |a|
  puts format("%-5s %-24s %s",
              FmrbRdHttp.field(a, "pid"),
              FmrbRdHttp.field(a, "name"),
              FmrbRdHttp.field(a, "state"))
end

#!/usr/bin/env ruby
# Move files to and from a Tab5 over WiFi, through the remote desktop's
# development file endpoints (/fs/list, /fs/get, /fs/put, /fs/del,
# /fs/mkdir; fmruby-core main/drivers/remote_desktop/rd_http.c).
#
# BLE was the only way to get a file off the device and it tops out at a few
# tens of KB/s -- fine for a .rb, hopeless for the JPEGs PicoRabbit exports or
# an MJPEG clip. WiFi moves several hundred KB/s. Paths are the ones apps use
# (/app, /home, /usr/share, /mnt/sd); the device refuses anything else.
#
#   ruby tools/fmrb_rd_fs.rb <IP> ls    <path>              # entries, sizes
#   ruby tools/fmrb_rd_fs.rb <IP> get   <path> [local]      # download
#   ruby tools/fmrb_rd_fs.rb <IP> put   <local> <path>      # upload (atomic on the device)
#   ruby tools/fmrb_rd_fs.rb <IP> del   <path>              # file, or empty directory
#   ruby tools/fmrb_rd_fs.rb <IP> mkdir <path>
#
# A typical development loop: put the app, launch it, look, kill it.
#
#   ruby tools/fmrb_rd_fs.rb $IP put my.app.rb /app/test/my.app.rb
#   ruby tools/fmrb_rd_launch.rb $IP /app/test/my.app.rb
#
# Exit status is 0 on success, 1 when the device answered with an error.

require "net/http"
require "json"
require "uri"

host = ARGV.shift or abort "usage: fmrb_rd_fs.rb HOST ls|get|put|del|mkdir ..."
cmd = ARGV.shift or abort "usage: fmrb_rd_fs.rb HOST ls|get|put|del|mkdir ..."

def request(host, klass, route, path, body: nil)
  uri = URI("http://#{host}#{route}?path=#{URI.encode_www_form_component(path)}")
  req = klass.new(uri)
  if body
    req.body = body
    req["Content-Type"] = "application/octet-stream"
  end
  Net::HTTP.start(uri.host, uri.port, read_timeout: 120, open_timeout: 10) do |http|
    http.request(req)
  end
end

# JSON answers carry ok:true/false; print the error and fail when it is false.
def expect_ok(res)
  doc = JSON.parse(res.body) rescue nil
  if doc.nil? || doc["ok"] != true
    err = doc ? doc["err"] : res.body[0, 200]
    warn "error: #{res.code} #{err}"
    exit 1
  end
  doc
end

case cmd
when "ls"
  path = ARGV.shift or abort "ls needs a path"
  doc = expect_ok(request(host, Net::HTTP::Get, "/fs/list", path))
  doc["entries"].sort_by { |e| [e["dir"] ? 0 : 1, e["name"]] }.each do |e|
    puts format("%s %10s  %s", e["dir"] ? "d" : "-", e["dir"] ? "" : e["size"], e["name"])
  end
when "get"
  path = ARGV.shift or abort "get needs a path"
  local = ARGV.shift || File.basename(path)
  res = request(host, Net::HTTP::Get, "/fs/get", path)
  if res.code != "200"
    expect_ok(res)
  end
  File.binwrite(local, res.body)
  puts "#{path} -> #{local} (#{res.body.bytesize} bytes)"
when "put"
  local = ARGV.shift or abort "put needs a local file and a device path"
  path = ARGV.shift or abort "put needs a device path"
  data = File.binread(local)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  doc = expect_ok(request(host, Net::HTTP::Put, "/fs/put", path, body: data))
  dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  puts format("%s -> %s (%d bytes, %.1f KB/s)", local, path, doc["size"], data.bytesize / 1024.0 / dt)
when "del"
  path = ARGV.shift or abort "del needs a path"
  expect_ok(request(host, Net::HTTP::Delete, "/fs/del", path))
  puts "deleted #{path}"
when "mkdir"
  path = ARGV.shift or abort "mkdir needs a path"
  doc = expect_ok(request(host, Net::HTTP::Post, "/fs/mkdir", path))
  puts(doc["existed"] ? "exists #{path}" : "created #{path}")
else
  abort "unknown command #{cmd} (ls|get|put|del|mkdir)"
end

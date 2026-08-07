#!/usr/bin/env ruby
# Grab one JPEG frame from the Tab5 remote desktop MJPEG stream.
# Usage: ruby fmrb_rd_snap.rb HOST out.jpg
require "socket"

host = ARGV[0] or abort "usage: fmrb_rd_snap.rb HOST out.jpg"
out = ARGV[1] or abort "usage: fmrb_rd_snap.rb HOST out.jpg"

s = TCPSocket.new(host, 80)
s.write("GET /stream HTTP/1.1\r\nHost: #{host}\r\nConnection: close\r\n\r\n")
buf = "".b
deadline = Time.now + 10
frame = nil
while Time.now < deadline
  chunk = s.readpartial(8192) rescue break
  buf << chunk
  soi = buf.index("\xFF\xD8".b)
  next unless soi
  eoi = buf.index("\xFF\xD9".b, soi + 2)
  next unless eoi
  frame = buf[soi..eoi + 1]
  break
end
s.close
abort "no frame captured" unless frame
File.binwrite(out, frame)
puts "#{out}: #{frame.bytesize} bytes"

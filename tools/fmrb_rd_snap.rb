#!/usr/bin/env ruby
# Grab one JPEG frame from the Tab5 remote desktop MJPEG stream.
# Usage: ruby fmrb_rd_snap.rb HOST out.jpg
#
# A release build shows its screen to a paired PC only (fmruby-core
# doc/remote_guard): the token kept by fmrb_rd_token.rb goes with the request.
require "socket"
require_relative "fmrb_rd_token"

host = ARGV[0] or abort "usage: fmrb_rd_snap.rb HOST out.jpg"
out = ARGV[1] or abort "usage: fmrb_rd_snap.rb HOST out.jpg"

# The token stored for this address, or (after a 401) the one found by the
# board's name: DHCP may have moved it since it was paired.
def open_stream(host, token)
  s = TCPSocket.new(host, 80)
  auth = token ? "#{FmrbRdToken::HEADER}: #{token}\r\n" : ""
  s.write("GET /stream HTTP/1.1\r\nHost: #{host}\r\n#{auth}Connection: close\r\n\r\n")
  s
end

def refused(s)
  head = +"".b
  deadline = Time.now + 5
  while Time.now < deadline && !head.include?("\r\n\r\n")
    break unless IO.select([s], nil, nil, 1)
    head << (s.readpartial(4096) rescue break)
  end
  [head[%r{\AHTTP/1\.[01] (\d+)}, 1].to_i == 401, head]
end

token = FmrbRdToken.token_for(host)
s = open_stream(host, token)
denied, head = refused(s)
if denied
  s.close
  fresh = FmrbRdToken.learn(host)
  if fresh && fresh != token
    s = open_stream(host, fresh)
    denied, head = refused(s)
  end
  abort FmrbRdToken.denied_message(host, head.split("\r\n\r\n", 2)[1].to_s).message if denied
end
buf = head.b
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

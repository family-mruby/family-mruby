#!/usr/bin/env ruby
# frozen_string_literal: true

# Read and write Zenoh keys from the PC through the zenohd router of the sim
# stack (the `zenohd` service in docker-compose.yml), using its REST plugin.
# Standard library only.
#
#   ruby tools/fmrb_zenoh.rb get fmrb/test/out          # latest value(s)
#   ruby tools/fmrb_zenoh.rb put fmrb/test/in hello     # publish a value
#   ruby tools/fmrb_zenoh.rb watch fmrb/test/out        # print changes
#
# `get` is a Zenoh query. It is answered by the router's in-memory storage on
# fmrb/** (configured in docker-compose.yml), which keeps the latest value of
# every key put under it -- so a key outside fmrb/** reads as empty. Key
# expressions with wildcards work (fmrb/** lists everything stored).
#
# A board on WiFi cannot reach the router by default: docker-compose.yml
# publishes zenohd on loopback only. Layer docker-compose.zenoh-lan.yml on top
# to open the Zenoh port (7447) to the LAN while a board needs it; the board
# then connects to tcp/<this PC's LAN address>:7447 (flash/app/test/
# zenoh_echo.app.rb reads that line from /home/zenoh_echo.txt):
#
#   docker compose -f docker-compose.yml -f docker-compose.zenoh-lan.yml up -d zenohd
#
# Background: fmruby-core/doc/ruby_asterism/ (plan.md, report/z1.md, z2.md).

require "base64"
require "json"
require "net/http"
require "optparse"
require "uri"

module FmrbZenoh
  module_function

  def base_uri(opts, key)
    key = key.sub(%r{\A/+}, "")
    URI("http://#{opts[:host]}:#{opts[:port]}/#{key}")
  end

  # The REST plugin returns text payloads as they are and binary ones
  # (zenoh/bytes, the default encoding of a plain put) in base64.
  def decode(entry)
    value = entry["value"]
    enc = entry["encoding"].to_s
    return value.to_s unless value.is_a?(String)
    if enc.start_with?("zenoh/bytes") || enc.start_with?("application/octet-stream")
      begin
        return Base64.strict_decode64(value).force_encoding("UTF-8")
      rescue ArgumentError
        return value
      end
    end
    value
  end

  def get(opts, key)
    uri = base_uri(opts, key)
    res = Net::HTTP.start(uri.host, uri.port, open_timeout: 3, read_timeout: opts[:timeout]) do |http|
      http.get(uri.request_uri)
    end
    raise "GET #{uri} -> #{res.code} #{res.body}" unless res.is_a?(Net::HTTPSuccess)
    JSON.parse(res.body).map { |e| [e["key"], decode(e), e["timestamp"]] }
  end

  def put(opts, key, value)
    uri = base_uri(opts, key)
    req = Net::HTTP::Put.new(uri.request_uri)
    req["Content-Type"] = "text/plain"
    req.body = value
    res = Net::HTTP.start(uri.host, uri.port, open_timeout: 3, read_timeout: opts[:timeout]) do |http|
      http.request(req)
    end
    raise "PUT #{uri} -> #{res.code} #{res.body}" unless res.is_a?(Net::HTTPSuccess)
  end

  def print_entries(entries)
    entries.each { |k, v, _ts| puts "#{k} = #{v}" }
  end

  def main(argv)
    opts = { host: ENV["FMRB_ZENOH_HOST"] || "localhost", port: 8000, interval: 0.5,
             timeout: 5, count: nil }
    parser = OptionParser.new do |o|
      o.banner = <<~USAGE
        Usage: ruby tools/fmrb_zenoh.rb [options] get <key>
               ruby tools/fmrb_zenoh.rb [options] put <key> <value>
               ruby tools/fmrb_zenoh.rb [options] watch <key>

        Talks to the zenohd REST plugin (docker compose service `zenohd`).
        For a board on WiFi, open the Zenoh port to the LAN first:
          docker compose -f docker-compose.yml -f docker-compose.zenoh-lan.yml up -d zenohd
        and point the board at tcp/<this PC's LAN address>:7447.

          get    print the latest stored value of each key matching <key>
                 (exit 1 when there is none)
          put    publish <value> (text) on <key>
          watch  poll <key> and print each value that changed, until Ctrl-C

      USAGE
      o.on("--host HOST", "REST host (default: localhost, or $FMRB_ZENOH_HOST)") { |v| opts[:host] = v }
      o.on("--port PORT", Integer, "REST port (default: 8000)") { |v| opts[:port] = v }
      o.on("--interval SEC", Float, "watch: polling interval (default: 0.5)") { |v| opts[:interval] = v }
      o.on("--count N", Integer, "watch: stop after N changes") { |v| opts[:count] = v }
      o.on("--timeout SEC", Integer, "HTTP read timeout (default: 5)") { |v| opts[:timeout] = v }
      o.on("-h", "--help", "show this help") do
        puts o
        exit 0
      end
    end
    args = parser.parse(argv)
    cmd = args.shift
    case cmd
    when "get"
      abort parser.to_s unless args.size == 1
      entries = get(opts, args[0])
      if entries.empty?
        warn "(no value for #{args[0]})"
        exit 1
      end
      print_entries(entries)
    when "put"
      abort parser.to_s unless args.size == 2
      put(opts, args[0], args[1])
      puts "put #{args[0]} = #{args[1]}"
    when "watch"
      abort parser.to_s unless args.size == 1
      seen = {}
      changes = 0
      loop do
        begin
          get(opts, args[0]).each do |k, v, ts|
            next if seen[k] == [v, ts]
            seen[k] = [v, ts]
            puts "#{Time.now.strftime('%H:%M:%S.%L')} #{k} = #{v}"
            $stdout.flush
            changes += 1
            exit 0 if opts[:count] && changes >= opts[:count]
          end
        rescue StandardError => e
          warn "#{Time.now.strftime('%H:%M:%S')} #{e.class}: #{e.message}"
        end
        sleep opts[:interval]
      end
    else
      abort parser.to_s
    end
  rescue Interrupt
    exit 130
  rescue Errno::ECONNREFUSED, Net::OpenTimeout, SocketError => e
    abort "cannot reach the zenohd REST plugin at #{opts[:host]}:#{opts[:port]} (#{e.class}). " \
          "Is the sim stack up (the zenohd service)?"
  rescue RuntimeError => e
    abort e.message
  end
end

FmrbZenoh.main(ARGV) if $PROGRAM_NAME == __FILE__

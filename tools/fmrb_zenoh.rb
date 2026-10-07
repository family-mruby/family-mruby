#!/usr/bin/env ruby
# frozen_string_literal: true

# Read and write Zenoh keys from the PC through the zenohd router of the sim
# stack (the `zenohd` service in docker-compose.yml), using its REST plugin.
# Standard library only.
#
#   ruby tools/fmrb_zenoh.rb get fmrb/test/out          # latest value(s)
#   ruby tools/fmrb_zenoh.rb put fmrb/test/in hello     # publish a value
#   ruby tools/fmrb_zenoh.rb watch fmrb/test/out        # print changes
#   ruby tools/fmrb_zenoh.rb query fmrb/node/linux/info # ask the queryables
#   ruby tools/fmrb_zenoh.rb alive                      # liveliness tokens
#   ruby tools/fmrb_zenoh.rb call linux/demo/info status  # call an Asterism object
#   ruby tools/fmrb_zenoh.rb meta linux/demo/apu          # its exposed methods
#
# `get` is a Zenoh query. It is answered by the router's in-memory storage on
# fmrb/** (configured in docker-compose.yml), which keeps the latest value of
# every key put under it -- so a key outside fmrb/** reads as empty. Key
# expressions with wildcards work (fmrb/** lists everything stored).
#
# `query` is the same Zenoh query, shown as a question to every queryable
# that matches (a board's Zenoh::Queryable, and the storage for fmrb/**): it
# prints each reply, with the elapsed time, and says so when none came.
# `alive` lists the liveliness tokens the router knows of, read from its
# admin space (@/<router id>/router/token/<key>); the REST plugin has no
# liveliness query of its own.
#
# `call` and `meta` talk to the objects an Asterism application exposes
# (fmruby-core/doc/ruby_asterism, A1): `call <node>/<app>/<object> <method>
# [<args JSON array>]` sends a get on asterism/<node>/<app>/<object>/call with
# the MessagePack payload [method, args, kwargs] in the request body, and
# decodes the reply (["ok", value] or ["error", class, message]). `meta` asks
# .../meta for the exposed methods; the object part may be * there.
# MessagePack is done by tools/fmrb_msgpack.rb (plain Ruby).
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
require_relative "fmrb_msgpack"

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

  # A query with a binary body (the query payload); replies as raw bytes.
  def query_bytes(opts, key, body)
    uri = base_uri(opts, key)
    req = Net::HTTP::Get.new(uri.request_uri)
    if body
      req["Content-Type"] = "application/octet-stream"
      req.body = body
    end
    res = Net::HTTP.start(uri.host, uri.port, open_timeout: 3, read_timeout: opts[:timeout]) do |http|
      http.request(req)
    end
    raise "GET #{uri} -> #{res.code} #{res.body}" unless res.is_a?(Net::HTTPSuccess)
    JSON.parse(res.body).map do |e|
      v = e["value"].to_s
      bytes = e["encoding"].to_s.start_with?("zenoh/bytes") ? Base64.strict_decode64(v) : v.b
      [e["key"], bytes]
    end
  end

  def asterism_path!(path)
    parts = path.split("/")
    raise "expected <node>/<app>/<object>, got #{path}" unless parts.size == 3 && parts.none?(&:empty?)
    path
  end

  def show_value(v)
    v.is_a?(String) ? v.inspect : JSON.generate(v)
  rescue JSON::GeneratorError
    v.inspect
  end

  # Returns the exit status.
  def asterism_call(opts, path, method, args, kwargs)
    payload = FmrbMsgpack.pack([method, args, kwargs])
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    replies = query_bytes(opts, "asterism/#{asterism_path!(path)}/call", payload)
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
    if replies.empty?
      warn "(no answer from #{path}, #{ms} ms)"
      return 1
    end
    status = 0
    replies.each do |key, bytes|
      reply = begin
        FmrbMsgpack.unpack(bytes)
      rescue FmrbMsgpack::Error => e
        warn "#{key}: not MessagePack (#{e.message})"
        status = 1
        next
      end
      if reply.is_a?(Array) && reply[0] == "ok"
        puts "ok: #{show_value(reply[1])}"
      elsif reply.is_a?(Array) && reply[0] == "error"
        puts "error: #{reply[1]}: #{reply[2]}"
        status = 1
      else
        puts "?: #{reply.inspect}"
        status = 1
      end
    end
    puts "(#{path} #{method}, #{ms} ms)"
    status
  end

  def asterism_meta(opts, path)
    parts = path.split("/")
    raise "expected <node>/<app>/<object>, got #{path}" unless parts.size == 3
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    replies = query_bytes(opts, "asterism/#{path}/meta", nil)
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
    if replies.empty?
      warn "(no answer from #{path}, #{ms} ms)"
      return 1
    end
    replies.each do |key, bytes|
      meta = FmrbMsgpack.unpack(bytes)
      obj = key.sub(%r{\Aasterism/}, "").sub(%r{/meta\z}, "")
      list = (meta["methods"] || []).map { |name, arity| arity.to_i < 0 ? name : "#{name}/#{arity}" }
      puts "#{obj}: #{list.join(' ')}"
    end
    puts "(#{replies.size} #{replies.size == 1 ? 'object' : 'objects'}, #{ms} ms)"
    0
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

  # Liveliness tokens under key (default fmrb/alive/**), from the router's
  # admin space.
  def alive(opts, key)
    get(opts, "@/*/router/token/#{key}").map { |k, _v, _ts| k.sub(%r{\A@/[^/]+/router/token/}, "") }.uniq.sort
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
               ruby tools/fmrb_zenoh.rb [options] query <key> [<parameters>]
               ruby tools/fmrb_zenoh.rb [options] alive [<key>]
               ruby tools/fmrb_zenoh.rb [options] call <node>/<app>/<object> <method> [<args JSON>]
               ruby tools/fmrb_zenoh.rb [options] meta <node>/<app>/<object>

        Talks to the zenohd REST plugin (docker compose service `zenohd`).
        For a board on WiFi, open the Zenoh port to the LAN first:
          docker compose -f docker-compose.yml -f docker-compose.zenoh-lan.yml up -d zenohd
        and point the board at tcp/<this PC's LAN address>:7447.

          get    print the latest stored value of each key matching <key>
                 (exit 1 when there is none)
          put    publish <value> (text) on <key>
          watch  poll <key> and print each value that changed, until Ctrl-C
          query  send a query on <key> (parameters as in key?a=1) and print
                 every reply (exit 1 when none came)
          alive  list the liveliness tokens under <key> (default fmrb/alive/**)
          call   call <method> of an Asterism object with the arguments of
                 the JSON array (a single JSON value is one argument; --kw
                 adds keyword arguments) and print the value or the error
                 (exit 1 on an error or no answer)
          meta   print the exposed methods (name/number of arguments) of an
                 Asterism object (<object> may be *)

      USAGE
      o.on("--host HOST", "REST host (default: localhost, or $FMRB_ZENOH_HOST)") { |v| opts[:host] = v }
      o.on("--port PORT", Integer, "REST port (default: 8000)") { |v| opts[:port] = v }
      o.on("--interval SEC", Float, "watch: polling interval (default: 0.5)") { |v| opts[:interval] = v }
      o.on("--count N", Integer, "watch: stop after N changes") { |v| opts[:count] = v }
      o.on("--timeout SEC", Integer, "HTTP read timeout (default: 5)") { |v| opts[:timeout] = v }
      o.on("--kw JSON", "call: keyword arguments as a JSON object") { |v| opts[:kw] = JSON.parse(v) }
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
    when "query"
      abort parser.to_s unless [1, 2].include?(args.size)
      key = args[1] ? "#{args[0]}?#{args[1]}" : args[0]
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      entries = get(opts, key)
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
      if entries.empty?
        warn "(no reply for #{key}, #{ms} ms)"
        exit 1
      end
      print_entries(entries)
      puts "(#{entries.size} #{entries.size == 1 ? 'reply' : 'replies'}, #{ms} ms)"
    when "alive"
      abort parser.to_s unless args.size <= 1
      keys = alive(opts, args[0] || "fmrb/alive/**")
      if keys.empty?
        warn "(no liveliness token)"
        exit 1
      end
      keys.each { |k| puts k }
    when "call"
      abort parser.to_s unless [2, 3].include?(args.size)
      call_args = args[2] ? JSON.parse(args[2]) : []
      call_args = [call_args] unless call_args.is_a?(Array)
      exit asterism_call(opts, args[0], args[1], call_args, opts[:kw] || {})
    when "meta"
      abort parser.to_s unless args.size == 1
      exit asterism_meta(opts, args[0])
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

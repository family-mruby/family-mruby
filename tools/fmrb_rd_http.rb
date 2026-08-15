# Shared HTTP for the development remote-control tools (fmrb_rd_launch /
# fmrb_rd_kill / fmrb_rd_ps). Standard library only, like the rest of tools/.
#
# The endpoints are plain HTTP and answer JSON, so curl works just as well --
# these exist to be short to type, not to hide anything:
#
#   curl -X POST "http://<IP>/app/launch?path=/app/modern/mic_spectrum.app.rb"
#
# They are compiled in only when the firmware is built with
# FMRB_DEV_REMOTE_CTL (doc/dev_remote_ctl/plan.md); against a build without it
# the server answers 404, which is reported as such rather than as a crash.
require "socket"

module FmrbRdHttp
  module_function

  def request(host, method, path, timeout: 10)
    s = TCPSocket.new(host, 80)
    s.write("#{method} #{path} HTTP/1.1\r\nHost: #{host}\r\n" \
            "Content-Length: 0\r\nConnection: close\r\n\r\n")

    # Read with a real deadline. A bare readpartial blocks with no regard for
    # any timeout the caller thinks it set, and the server does not always drop
    # the connection the moment it has answered -- so wait on the socket, and
    # stop as soon as Content-Length says the body is complete.
    buf = +""
    deadline = Time.now + timeout
    loop do
      remaining = deadline - Time.now
      break if remaining <= 0
      break unless IO.select([s], nil, nil, remaining)
      begin
        buf << s.readpartial(4096)
      rescue EOFError
        break
      end
      head, sep, body = buf.partition("\r\n\r\n")
      next if sep.empty?
      len = head[/^Content-Length:\s*(\d+)/i, 1]
      break if len && body.bytesize >= len.to_i
    end
    s.close rescue nil

    head, _, body = buf.partition("\r\n\r\n")
    status = head[%r{\AHTTP/1\.[01] (\d+)}, 1].to_i
    abort "no response from #{host} within #{timeout}s" if status.zero?
    [status, body.strip]
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
    abort "cannot reach #{host}: #{e.message}"
  end

  # The responses are small and flat, so a regexp reader beats requiring json
  # for the two or three keys these tools want.
  def field(body, key)
    body[/"#{Regexp.escape(key)}"\s*:\s*"([^"]*)"/, 1] ||
      body[/"#{Regexp.escape(key)}"\s*:\s*(-?\d+|true|false)/, 1]
  end

  # Explain a 404 rather than leaving the caller to guess: the overwhelmingly
  # likely cause is a firmware built without the dev endpoints.
  def check_status(status, body)
    if status == 404 && !body.include?("\"ok\"")
      abort "404: this firmware has no development remote control " \
            "(build with FMRB_DEV_REMOTE_CTL, see doc/dev_remote_ctl/plan.md)"
    end
  end
end

# frozen_string_literal: true

# Shared plumbing for the fmrb MCP server: the error the tools turn into a
# tool-level failure, and the two things every wrapper here needs -- running a
# child process without letting it near our stdout, and making arbitrary bytes
# safe to put in a JSON-RPC response.
module FmrbMcp
  class Error < StandardError; end

  module Sub
    module_function

    # Runs a command, captures stdout+stderr together, and never blocks past
    # `timeout`. The child gets its own process group so a timeout can take
    # the whole tree down rather than orphaning it.
    def run(env, cmd, chdir:, timeout:)
      r, w = IO.pipe
      r.binmode
      pid = begin
        Process.spawn(env, *cmd, chdir: chdir, in: File::NULL,
                      out: w, err: [:child, :out], pgroup: true)
      rescue Errno::ENOENT => e
        r.close
        w.close
        raise Error, "cannot run #{cmd.first}: #{e.message} (is it on PATH for this server?)"
      end
      w.close

      buf = +""
      reader = Thread.new { buf << r.read }

      status = nil
      timed_out = false
      deadline = Time.now + timeout
      loop do
        _, status = Process.waitpid2(pid, Process::WNOHANG)
        break if status
        if Time.now > deadline
          timed_out = true
          Process.kill("TERM", -pid) rescue nil
          sleep 2
          Process.kill("KILL", -pid) rescue nil
          Process.waitpid(pid) rescue nil
          break
        end
        sleep 0.2
      end

      reader.join(5)
      r.close rescue nil

      { ok: (!timed_out && status&.success?) || false,
        status: status&.exitstatus, timed_out: timed_out,
        output: scrub(buf) }
    end

    # Serial output and command output are bytes, not text: they can hold
    # partial UTF-8 (a log read while it is being written) and ANSI colour from
    # ESP-IDF. Either would break JSON generation or the readability of the
    # result.
    def scrub(bytes)
      bytes.force_encoding(Encoding::UTF_8)
           .scrub("?")
           .gsub(/\e\[[0-9;]*[A-Za-z]/, "")
           .gsub("\r\n", "\n")
           .delete("\r")
    end

    def clamp(text, limit)
      return text if text.bytesize <= limit
      tail = text.byteslice(text.bytesize - limit, limit)
                 .force_encoding(Encoding::UTF_8).scrub("?")
      "...(truncated #{text.bytesize - limit} bytes)...\n" + tail.sub(/\A[^\n]*\n/, "")
    end
  end
end

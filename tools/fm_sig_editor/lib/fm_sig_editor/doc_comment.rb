# frozen_string_literal: true

module FmSigEditor
  # One doc comment, split the way the firmware reads it.
  #
  # The first line is the summary: it is the only part that reaches the type
  # database, and the editor copies it into a fixed buffer -- 112 bytes with
  # the terminator, so 111 bytes of text survive and the rest is dropped
  # without a word (ET_DOC_MAX in editor_ti_bridge.c).
  #
  # Everything below the summary is the long form, written out as
  # flash/help/<Class>/<member>.md and opened with F1. It has no length limit.
  #
  # Both halves carry two languages. In the summary the marker sits inline
  # ("日本語 <<en>> English"); in the long form it is a line of its own. The
  # editor picks a side at display time; a comment with no marker shows the one
  # language it has to everybody.
  class DocComment
    MARKER = "<<en>>"
    # 112 is the buffer; the last byte is the terminator.
    SUMMARY_MAX_BYTES = 111
    # The help pane wraps at about this width. Prose survives it -- a code
    # block does not, because it breaks mid-token.
    HELP_COLUMNS = 39

    attr_accessor :summary_ja, :summary_en, :long_ja, :long_en

    def initialize(summary_ja: "", summary_en: "", long_ja: "", long_en: "")
      @summary_ja = summary_ja
      @summary_en = summary_en
      @long_ja = long_ja
      @long_en = long_en
    end

    # text: the comment with its "#" and one following space removed.
    def self.parse(text)
      lines = text.to_s.lines.map { |l| l.chomp }
      summary = lines.shift.to_s
      ja, en = split_inline(summary)
      lines.shift while lines.first && lines.first.strip.empty?
      long_ja, long_en = split_block(lines)
      new(summary_ja: ja, summary_en: en, long_ja: long_ja, long_en: long_en)
    end

    def self.split_inline(line)
      return [line.strip, ""] unless line.include?(MARKER)

      ja, en = line.split(MARKER, 2)
      [ja.to_s.strip, en.to_s.strip]
    end

    def self.split_block(lines)
      at = lines.index { |l| l.strip == MARKER }
      return [lines.join("\n").rstrip, ""] if at.nil?

      [lines[0...at].join("\n").rstrip, lines[(at + 1)..].to_a.join("\n").rstrip]
    end

    def summary_line
      return summary_ja if summary_en.to_s.strip.empty?

      "#{summary_ja} #{MARKER} #{summary_en}"
    end

    def summary_bytes
      summary_line.bytesize
    end

    def summary_over?
      summary_bytes > SUMMARY_MAX_BYTES
    end

    def long?
      !long_ja.to_s.strip.empty? || !long_en.to_s.strip.empty?
    end

    # The comment as text again, ready to be given "#" back.
    def to_text
      out = [summary_line]
      if long?
        out << ""
        out.concat(long_ja.to_s.rstrip.split("\n", -1)) unless long_ja.to_s.strip.empty?
        unless long_en.to_s.strip.empty?
          out << MARKER
          out.concat(long_en.to_s.rstrip.split("\n", -1))
        end
      end
      out.join("\n")
    end

    # Lines inside a ```...``` block that will not fit the help pane. They are
    # the ones worth reporting: a wrapped path or call reads as broken, while
    # wrapped prose does not.
    def wide_code_lines
      found = []
      [long_ja, long_en].each do |body|
        inside = false
        body.to_s.each_line.with_index do |line, i|
          line = line.chomp
          if line.strip.start_with?("```")
            inside = !inside
            next
          end
          found << [i + 1, line] if inside && line.length > HELP_COLUMNS
        end
      end
      found
    end
  end
end

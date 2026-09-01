# frozen_string_literal: true

# The one thing this editor must not do is disturb a file it was only looking
# at. Every comment in sig/ is parsed and written back; the file has to come
# out byte for byte as it went in.
#
#   ruby tools/fm_sig_editor/test/round_trip_test.rb [sig dir]

require "tmpdir"
require "fileutils"
require_relative "../lib/fm_sig_editor"

sig_dir = ARGV[0] || FmSigEditor.default_sig_dir
abort "no sig directory at #{sig_dir}" unless Dir.exist?(sig_dir)

failures = 0
checked = 0
entries_seen = 0

Dir.glob(File.join(sig_dir, "*.rbs")).sort.each do |path|
  original = File.read(path)
  Dir.mktmpdir do |tmp|
    copy = File.join(tmp, File.basename(path))
    FileUtils.cp(path, copy)
    file = FmSigEditor::SigFile.new(copy)
    entries_seen += file.entries.size
    # Save every entry unchanged, one after another.
    file.entries.size.times do |i|
      entry = file.entries[i]
      file.save(entry)
    end
    after = File.read(copy)
    checked += 1
    next if after == original

    failures += 1
    warn "#{File.basename(path)}: changed after a no-op round trip"
    original.lines.zip(after.lines).each_with_index do |(a, b), i|
      next if a == b

      warn "  line #{i + 1}"
      warn "    was: #{a.inspect}"
      warn "    now: #{b.inspect}"
      break
    end
  end
end

# The parts of a comment have to survive being taken apart and put together.
sample = [
  "日本語の要約 <<en>> the summary",
  "",
  "長い説明の一行目。",
  "```ruby",
  "gfx.present",
  "```",
  "<<en>>",
  "The long form.",
].join("\n")
doc = FmSigEditor::DocComment.parse(sample)
unless doc.summary_ja == "日本語の要約" && doc.summary_en == "the summary" &&
       doc.long_ja.include?("gfx.present") && doc.long_en == "The long form."
  failures += 1
  warn "DocComment.parse: split wrong: #{doc.inspect}"
end
unless FmSigEditor::DocComment.parse(doc.to_text).to_text == doc.to_text
  failures += 1
  warn "DocComment: not stable through a second parse"
end

# A summary at the limit is not over it; one byte more is.
at_limit = FmSigEditor::DocComment.new(summary_ja: "a" * FmSigEditor::DocComment::SUMMARY_MAX_BYTES)
over = FmSigEditor::DocComment.new(summary_ja: "a" * (FmSigEditor::DocComment::SUMMARY_MAX_BYTES + 1))
failures += 1 if at_limit.summary_over?
failures += 1 unless over.summary_over?

puts "round_trip_test: #{checked} file(s), #{entries_seen} entries, all unchanged" if failures.zero?

# An edit has to land where it was made, and nowhere else.
Dir.mktmpdir do |tmp|
  source = File.join(sig_dir, "fmrb_gfx.rbs")
  if File.exist?(source)
    copy = File.join(tmp, "fmrb_gfx.rbs")
    FileUtils.cp(source, copy)
    before = File.readlines(copy)

    file = FmSigEditor::SigFile.new(copy)
    entry = file.entries.find { |e| e.name == "present" } || file.entries.first
    range = entry.comment_range
    entry.doc.summary_en = "show what has been drawn (edited)"
    entry.doc.long_ja = "#{entry.doc.long_ja}\n足した行。"
    file.save(entry)

    after = File.readlines(copy)
    reread = FmSigEditor::SigFile.new(copy).entries.find { |e| e.name == entry.name }

    unless reread.doc.summary_en == "show what has been drawn (edited)"
      failures += 1
      warn "edit: summary did not survive the round trip"
    end
    unless reread.doc.long_ja.end_with?("足した行。")
      failures += 1
      warn "edit: long help did not survive the round trip"
    end
    # Everything above the comment, and the signature line below it, untouched.
    unless before[0...(range.first - 1)] == after[0...(range.first - 1)]
      failures += 1
      warn "edit: lines above the comment changed"
    end
    tail_before = before[(range.last)..]
    tail_after = after[(after.size - tail_before.size)..]
    unless tail_before == tail_after
      failures += 1
      warn "edit: lines below the comment changed"
    end
    begin
      RBS::Parser.parse_signature(RBS::Buffer.new(name: copy, content: File.read(copy)))
    rescue StandardError => e
      failures += 1
      warn "edit: the file no longer parses: #{e.message}"
    end
    puts "edit test: #{entry.title} rewritten in place" if failures.zero?
  end
end

if failures.zero?
  puts "round_trip_test: all checks passed"
  exit 0
end
warn "round_trip_test: #{failures} failure(s) (edit stage)"
exit 1

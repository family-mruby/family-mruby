#!/usr/bin/env ruby
# Rewrite the text fields of an NSF header to plain ASCII.
#
# The on-device NSF player renders text with an ASCII font, so SJIS-titled
# rips (the common case for Japanese NSFs) display as garbage. Rather than
# teach the firmware SJIS, rewrite the file: decode each text field as CP932,
# transliterate kana to Hepburn romaji, keep ASCII as-is, and drop what has
# no ASCII form (kanji). The three fields are fixed 32-byte NUL-padded slots
# at offsets 14 (song name), 46 (artist), 78 (copyright); nothing else in the
# file is touched, so playback is unaffected.
#
# Usage:
#   ruby tools/nsf_ascii_header.rb file.nsf [more.nsf ...]        # preview only
#   ruby tools/nsf_ascii_header.rb -w file.nsf [more.nsf ...]     # rewrite in place (.bak saved)
#   ruby tools/nsf_ascii_header.rb -w --title "My Song" file.nsf  # set the song name by hand
#                                  --artist "..." --copyright "..."
#
# A field that transliterates to nothing (all kanji) falls back to the
# filename for the song name, and to "" for artist/copyright -- check the
# preview and use --title and friends where the automatic result is poor.

NAME_OFF = 14
ARTIST_OFF = 46
COPY_OFF = 78
FIELD_LEN = 32

KANA = {
  "きゃ" => "kya", "きゅ" => "kyu", "きょ" => "kyo",
  "しゃ" => "sha", "しゅ" => "shu", "しょ" => "sho",
  "ちゃ" => "cha", "ちゅ" => "chu", "ちょ" => "cho",
  "にゃ" => "nya", "にゅ" => "nyu", "にょ" => "nyo",
  "ひゃ" => "hya", "ひゅ" => "hyu", "ひょ" => "hyo",
  "みゃ" => "mya", "みゅ" => "myu", "みょ" => "myo",
  "りゃ" => "rya", "りゅ" => "ryu", "りょ" => "ryo",
  "ぎゃ" => "gya", "ぎゅ" => "gyu", "ぎょ" => "gyo",
  "じゃ" => "ja",  "じゅ" => "ju",  "じょ" => "jo",
  "びゃ" => "bya", "びゅ" => "byu", "びょ" => "byo",
  "ぴゃ" => "pya", "ぴゅ" => "pyu", "ぴょ" => "pyo",
  "ふぁ" => "fa",  "ふぃ" => "fi",  "ふぇ" => "fe", "ふぉ" => "fo",
  "うぃ" => "wi",  "うぇ" => "we",  "てぃ" => "ti", "でぃ" => "di",
  "あ" => "a",  "い" => "i",  "う" => "u",  "え" => "e",  "お" => "o",
  "か" => "ka", "き" => "ki", "く" => "ku", "け" => "ke", "こ" => "ko",
  "さ" => "sa", "し" => "shi", "す" => "su", "せ" => "se", "そ" => "so",
  "た" => "ta", "ち" => "chi", "つ" => "tsu", "て" => "te", "と" => "to",
  "な" => "na", "に" => "ni", "ぬ" => "nu", "ね" => "ne", "の" => "no",
  "は" => "ha", "ひ" => "hi", "ふ" => "fu", "へ" => "he", "ほ" => "ho",
  "ま" => "ma", "み" => "mi", "む" => "mu", "め" => "me", "も" => "mo",
  "や" => "ya", "ゆ" => "yu", "よ" => "yo",
  "ら" => "ra", "り" => "ri", "る" => "ru", "れ" => "re", "ろ" => "ro",
  "わ" => "wa", "を" => "wo", "ん" => "n",
  "が" => "ga", "ぎ" => "gi", "ぐ" => "gu", "げ" => "ge", "ご" => "go",
  "ざ" => "za", "じ" => "ji", "ず" => "zu", "ぜ" => "ze", "ぞ" => "zo",
  "だ" => "da", "ぢ" => "ji", "づ" => "zu", "で" => "de", "ど" => "do",
  "ば" => "ba", "び" => "bi", "ぶ" => "bu", "べ" => "be", "ぼ" => "bo",
  "ぱ" => "pa", "ぴ" => "pi", "ぷ" => "pu", "ぺ" => "pe", "ぽ" => "po",
  "ぁ" => "a", "ぃ" => "i", "ぅ" => "u", "ぇ" => "e", "ぉ" => "o",
  "ゎ" => "wa",
}.freeze

def kata_to_hira(s)
  s.tr("ァ-ヶ", "ぁ-ゖ")
end

# UTF-8 Japanese -> best-effort romaji/ASCII. Non-convertible chars vanish.
def to_ascii(str)
  s = kata_to_hira(str)
  s = s.tr("０-９ａ-ｚＡ-Ｚ", "0-9a-zA-Z")   # fullwidth alnum
  s = s.tr("　・ー〜", " .-~")
  out = +""
  chars = s.chars
  i = 0
  while i < chars.length
    c = chars[i]
    if c.ord < 0x80
      out << c
      i += 1
    elsif c == "っ"
      # sokuon: double the next romaji consonant
      nxt2 = KANA[chars[i + 1].to_s + chars[i + 2].to_s] || KANA[chars[i + 1].to_s]
      out << nxt2[0] if nxt2
      i += 1
    elsif (two = KANA[c + chars[i + 1].to_s])
      out << two
      i += 2
    elsif (one = KANA[c])
      out << one
      i += 1
    else
      i += 1  # kanji etc.: no ASCII form, drop
    end
  end
  out.strip.squeeze(" ")
end

def read_field(data, off)
  raw = data[off, FIELD_LEN].sub(/\x00.*\z/mn, "")
  return [raw, raw] if raw.bytes.all? { |b| b < 0x80 }
  utf = raw.dup.force_encoding(Encoding::Windows_31J)
           .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
  [raw, to_ascii(utf)]
rescue StandardError
  [raw, raw.bytes.select { |b| b >= 0x20 && b < 0x7F }.pack("C*")]
end

def write_field(data, off, text)
  field = text.b[0, FIELD_LEN - 1].to_s
  data[off, FIELD_LEN] = field + "\x00" * (FIELD_LEN - field.bytesize)
end

write = ARGV.delete("-w")
overrides = {}
{ "--title" => NAME_OFF, "--artist" => ARTIST_OFF, "--copyright" => COPY_OFF }.each do |flag, off|
  if (i = ARGV.index(flag))
    overrides[off] = ARGV.delete_at(i + 1)
    ARGV.delete_at(i)
  end
end
abort "usage: nsf_ascii_header.rb [-w] [--title T] [--artist A] [--copyright C] file.nsf ..." if ARGV.empty?

ARGV.each do |path|
  data = File.binread(path)
  unless data.bytesize >= 128 && data[0, 5] == "NESM\x1A".b
    warn "#{path}: not an NSF (bad magic), skipped"
    next
  end
  changed = false
  { NAME_OFF => "title", ARTIST_OFF => "artist", COPY_OFF => "copyright" }.each do |off, label|
    raw, ascii = read_field(data, off)
    ascii = overrides[off] if overrides.key?(off)
    if off == NAME_OFF && ascii.empty? && !raw.empty?
      ascii = File.basename(path, ".nsf")
    end
    next if raw == ascii

    puts "#{path}: #{label}: #{raw.inspect} -> #{ascii.inspect}"
    write_field(data, off, ascii)
    changed = true
  end
  if !changed
    puts "#{path}: already ASCII, nothing to do"
  elsif write
    File.binwrite("#{path}.bak", File.binread(path))
    File.binwrite(path, data)
    puts "#{path}: rewritten (backup: #{path}.bak)"
  else
    puts "#{path}: preview only (-w to rewrite)"
  end
end

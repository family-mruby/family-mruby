#!/usr/bin/env ruby
# frozen_string_literal: true

# Open and re-save every asset in the tree and check the bytes come back
# unchanged. This is what keeps the editor from putting noise in diffs, and it
# is the only test that can run without a display, so run it after touching
# anything under lib/.
#
#   ruby tools/fm_asset_editor/test/round_trip_test.rb

require 'tmpdir'
require_relative '../lib/fm_asset_editor'

ROOT = File.expand_path('../../..', __dir__)
PATTERNS = [
  'fmruby-core/flash/**/*.bmp',
  'fmruby-graphics-audio/flash/**/*.bmp'
].freeze

failures = []
checked = 0

def check(message, failures)
  ok = yield
  failures << message unless ok
  ok
end

Dir.mktmpdir do |tmp|
  out = File.join(tmp, 'out.bmp')

  Dir.chdir(ROOT) do
    PATTERNS.flat_map { |pattern| Dir.glob(pattern) }.sort.each do |path|
      format = FmAssetEditor::Format.find(path)
      next failures << "#{path}: no format claims it" if format.nil?

      document = format.load(path)
      document.save(out)
      checked += 1
      check("#{path}: bytes changed on a plain open/save", failures) do
        File.binread(out) == File.binread(path)
      end
    end
  end

  # Editing, undo and redo have to land on exactly the original bytes.
  sheet = File.join(ROOT, 'fmruby-core/flash/usr/share/basic/font_b.bmp')
  document = FmAssetEditor::Format.find(sheet).load(sheet)
  before = document.pixels.dup
  document.set(3, 3, 2)
  document.set(4, 3, 2)
  document.commit_stroke
  check('undo did not restore the pixels', failures) { document.undo && document.pixels == before }
  check('redo did not re-apply the edit', failures) { document.redo && document.get(3, 3) == 2 }
  check('second undo did not restore the pixels', failures) { document.undo && document.pixels == before }
  document.save(out)
  check('undone edit still changed the file', failures) { File.binread(out) == File.binread(sheet) }

  # Fill covers a whole run and undoes as one step.
  sprite = FmAssetEditor::Formats::Sprite332.blank(8, 8)
  sprite.fill(0, 0, 0xE0)
  sprite.commit_stroke
  check('fill did not cover the sprite', failures) { sprite.pixels.uniq == [0xE0] }
  check('fill did not undo in one step', failures) { sprite.undo && sprite.pixels.uniq == [0] }

  # A sprite written from scratch carries the canonical RGB332 palette.
  sprite = FmAssetEditor::Formats::Sprite332.blank(4, 4)
  sprite.set(1, 1, 0xE0)
  sprite.save(out)
  image = FmAssetEditor::Bmp.read(out)
  check('a new sprite did not get the RGB332 palette', failures) do
    image.palette == FmAssetEditor::Rgb332::PALETTE && image.color_count == 256
  end
  check('a new sprite lost its pixel', failures) { image.pixels[1 * 4 + 1] == 0xE0 }

  # The size the loader refuses must be refused here too.
  big = FmAssetEditor::Formats::Sprite332.blank(257, 4)
  check('an oversized sprite was written anyway', failures) do
    begin
      big.save(out)
      false
    rescue FmAssetEditor::Bmp::Error
      true
    end
  end
end

if failures.empty?
  puts "ok: #{checked} assets round-tripped byte for byte, edit/undo/limits pass"
else
  failures.each { |message| warn "FAIL #{message}" }
  warn "#{failures.size} failure(s)"
  exit 1
end

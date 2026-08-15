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

  # The three ways of naming a colour have to agree. Levels are the hardware
  # steps (0-7, 0-7, 0-3); hex is either the RGB332 byte or a 24-bit colour to
  # quantise.
  check('levels do not round-trip through every value', failures) do
    (0..255).all? { |value| FmAssetEditor::Rgb332.from_levels(*FmAssetEditor::Rgb332.levels(value)) == value }
  end
  {
    '5E' => 0x5E, '0x5e' => 0x5E, '#5E' => 0x5E, ' ff ' => 0xFF,
    'ff8000' => 0xEC, '#ff8000' => 0xEC, 'f80' => 0xEC,
    'zz' => nil, '' => nil, '12345' => nil
  }.each do |text, want|
    check("hex #{text.inspect} parsed as #{FmAssetEditor::Rgb332.parse(text).inspect}, wanted #{want.inspect}", failures) do
      FmAssetEditor::Rgb332.parse(text) == want
    end
  end

  # The folders the dialogs start in survive a restart, and a folder that has
  # gone away is forgotten rather than handed to the dialog.
  state = File.join(tmp, 'config', 'state.json')
  settings = FmAssetEditor::Settings.new(state)
  check('a fresh settings file remembered something', failures) { settings.directory(:open).nil? }
  settings.remember(:open, tmp)
  settings.remember(:save, ROOT)
  reloaded = FmAssetEditor::Settings.new(state)
  check('the open folder was not kept', failures) { reloaded.directory(:open) == tmp }
  check('the save folder was not kept', failures) { reloaded.directory(:save) == ROOT }
  check('open and save share one folder', failures) { reloaded.directory(:open) != reloaded.directory(:save) }
  gone = File.join(tmp, 'gone')
  Dir.mkdir(gone)
  settings.remember(:open, gone)
  Dir.rmdir(gone)
  check('a folder that no longer exists was still offered', failures) do
    FmAssetEditor::Settings.new(state).directory(:open).nil?
  end
  File.write(state, 'not json at all')
  check('a damaged settings file was not shrugged off', failures) do
    FmAssetEditor::Settings.new(state).directory(:open).nil?
  end

  # Tunes: the file is read the way the device reads it, and what the parser
  # would quietly ignore is pointed out rather than left to become silence.
  tune_path = File.join(tmp, 'round.mml')
  File.write(tune_path, <<~MML)
    # Round - two parts, both eight beats long
    bpm 90
    loop on
    o5 l4 cegegegc
    velocity 80
    o3 l2 c   g   c   r
  MML
  format = FmAssetEditor::Format.find(tune_path)
  check('no format claims a .mml file', failures) { format == FmAssetEditor::Formats::MmlTune }

  document = format.load(tune_path)
  tune = document.tune
  check("the tune read #{tune.bpm} BPM, wanted 90", failures) { tune.bpm == 90 }
  check('loop on was not read', failures) { tune.loop? == true }
  check("parts read as #{tune.part_count}, wanted 2", failures) { tune.part_count == 2 }
  check('the parts did not get a channel each', failures) do
    tune.parts.map(&:channel) == [0, 1]
  end
  check('velocity did not apply to the part below it', failures) do
    tune.parts.map(&:velocity) == [100, 80]
  end
  check("a clean tune reported #{tune.problems.inspect}", failures) { tune.problems.empty? }

  # Editing a setting rewrites one line and leaves the rest alone.
  document.set_setting('bpm', 140)
  check('changing the tempo did not rewrite the bpm line', failures) do
    document.text.include?('bpm 140') && !document.text.include?('bpm 90')
  end
  check('changing the tempo disturbed the parts', failures) do
    document.text.include?('o5 l4 cegegegc') && document.text.include?('velocity 80')
  end
  document.save
  check('the saved tune does not read back the same', failures) do
    format.load(tune_path).text == document.text
  end

  # The four sound settings: what plays a part, which the dialect cannot say.
  voiced = FmAssetEditor::Mml::Tune.new(<<~MML)
    bpm 120
    voice triangle
    duty 1
    volume 100
    program 118
    o3 l4 cde
    voice noise
    o3 l4 fga
  MML
  check('the sound settings did not reach the first part', failures) do
    part = voiced.parts.first
    part.voice == 'triangle' && part.duty == 1 && part.volume == 100 && part.program == 118
  end
  check('a sound setting did not carry to the part below it', failures) do
    voiced.parts.last.voice == 'noise' && voiced.parts.last.duty == 1
  end
  check("a clean voiced tune reported #{voiced.problems.inspect}", failures) { voiced.problems.empty? }
  check('a bad voice name was accepted', failures) do
    FmAssetEditor::Mml::Tune.new("voice bagpipes\nc").problems.any? { |p| p.message.include?('voice') }
  end
  check('the numbers the transport uses were not accepted for a voice', failures) do
    FmAssetEditor::Mml::Tune.new("voice 2\nc").parts.first.voice == 'triangle'
  end

  if FmAssetEditor::Mml::Engine.available?
    # Each setting has to change the sound, or the preview is telling a story.
    render = lambda do |settings|
      FmAssetEditor::Mml::Audio.render(FmAssetEditor::Mml::Tune.new("bpm 120\n#{settings}o4 l4 c\n"))
    end
    square = render.call('')
    # Well inside the note: the fades at either end and the tail the DC filter
    # leaves behind are not what the duty is about.
    positive = lambda do |wav|
      samples = wav[44..].unpack('s<*')[2000, 8000]
      samples.count(&:positive?).to_f / samples.size
    end
    check('duty 0 did not narrow the pulse', failures) { (positive.call(render.call("duty 0\n")) - 0.125).abs < 0.02 }
    check('duty 2 is not a square', failures) { (positive.call(square) - 0.5).abs < 0.02 }
    check('the triangle sounds like the pulse', failures) { render.call("voice triangle\n") != square }
    check('the noise sounds like the pulse', failures) { render.call("voice noise\n") != square }
    check('volume did not change the level', failures) do
      peak = lambda { |wav| wav[44..].unpack('s<*').map(&:abs).max }
      quiet = peak.call(render.call("volume 64\n"))
      loud = peak.call(square)
      quiet < loud * 0.6 && quiet > loud * 0.4
    end
    check('the GM name of program 118 was not found', failures) do
      FmAssetEditor::Mml::Engine.gm_name(118) == 'Synth Drum'
    end

    # Parts that do not end together: the player takes the longest as the
    # length, so the short one waits for the repeat and whatever made the long
    # one long has been playing against the wrong bar.
    ragged = FmAssetEditor::Mml::Tune.new("bpm 120\no4 l4 cdef cdef\no3 l4 cdef cde\n")
    check('a part a beat short was not reported', failures) do
      ragged.problems.any? { |problem| problem.line == 3 && problem.message.include?('1 beat') }
    end
    check('a bar short was not counted in bars', failures) do
      FmAssetEditor::Mml::Tune.new("bpm 120\no4 l1 cd\no3 l1 c\n").problems
                              .any? { |problem| problem.message.include?('1 bar') }
    end
    check('parts of one length were complained about', failures) do
      FmAssetEditor::Mml::Tune.new("bpm 120\no4 l4 cdef\no3 l4 cdef\n").problems.empty?
    end
  end

  stray = FmAssetEditor::Mml::Tune.new("bpm 120\no4 l8 cde fg@ab")
  check('a character the parser ignores was not reported', failures) do
    stray.problems.any? { |problem| problem.line == 2 && problem.message.include?('@') }
  end
  bad = FmAssetEditor::Mml::Tune.new("bpm fast\nloop maybe\nc")
  check('nonsense settings were accepted quietly', failures) { bad.problems.size >= 2 }
  check('a bad tempo did not fall back to the default', failures) { bad.bpm == 120 }

  # The events come from the machine's own parser, so this only runs where the
  # core checkout is next to the tool.
  if FmAssetEditor::Mml::Engine.available?
    scale = FmAssetEditor::Mml::Tune.new("bpm 120\no4 l8 crdrerfrgrarbr>cr")
    check("the scale has #{scale.note_count} notes, wanted 8", failures) { scale.note_count == 8 }
    check("the scale runs #{scale.seconds}s, wanted 4", failures) { (scale.seconds - 4.0).abs < 0.01 }
    wav = FmAssetEditor::Mml::Audio.render(scale)
    check('no wav came out of the tune', failures) { !wav.nil? && wav.start_with?('RIFF') }
    check('the wav is not as long as the tune', failures) do
      samples = (wav.bytesize - 44) / 2.0 / FmAssetEditor::Mml::Audio::RATE
      (samples - (4.0 + FmAssetEditor::Mml::Audio::TAIL)).abs < 0.05
    end
    silent = FmAssetEditor::Mml::Tune.new("bpm 120\n")
    check('a tune with no parts still rendered', failures) { FmAssetEditor::Mml::Audio.render(silent).nil? }
  else
    puts "note: skipped the tune preview checks (#{FmAssetEditor::Mml::Engine.unavailable_reason})"
  end

  # The GSettings backend is only forced when the session bus really is missing,
  # and never over an explicit setting.
  require 'socket'
  bus = ENV['DBUS_SESSION_BUS_ADDRESS']
  backend = ENV['GSETTINGS_BACKEND']
  begin
    ENV.delete('GSETTINGS_BACKEND')
    ENV['DBUS_SESSION_BUS_ADDRESS'] = "unix:path=#{File.join(tmp, 'no-such-bus')}"
    FmAssetEditor.quiet_gsettings
    check('a missing session bus did not switch the backend', failures) do
      ENV['GSETTINGS_BACKEND'] == 'memory'
    end

    socket_path = File.join(tmp, 'bus')
    server = UNIXServer.new(socket_path)
    ENV.delete('GSETTINGS_BACKEND')
    ENV['DBUS_SESSION_BUS_ADDRESS'] = "unix:path=#{socket_path},guid=abc"
    FmAssetEditor.quiet_gsettings
    check('a working session bus was overridden anyway', failures) { ENV['GSETTINGS_BACKEND'].nil? }
    server.close

    ENV['GSETTINGS_BACKEND'] = 'dconf'
    ENV['DBUS_SESSION_BUS_ADDRESS'] = "unix:path=#{File.join(tmp, 'no-such-bus')}"
    FmAssetEditor.quiet_gsettings
    check('an explicit backend was not left alone', failures) { ENV['GSETTINGS_BACKEND'] == 'dconf' }
  ensure
    bus.nil? ? ENV.delete('DBUS_SESSION_BUS_ADDRESS') : ENV['DBUS_SESSION_BUS_ADDRESS'] = bus
    backend.nil? ? ENV.delete('GSETTINGS_BACKEND') : ENV['GSETTINGS_BACKEND'] = backend
  end

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

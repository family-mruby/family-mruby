# frozen_string_literal: true

module FmAssetEditor
  module Mml
    # The machine's own MML parser, borrowed.
    #
    # MIDI::MML::Sequence lives in fmruby-core as an unchanged import from
    # Midori (lib/add/picoruby-midi-mml). It is plain Ruby depending on nothing
    # but itself, so the editor loads that very file rather than reimplementing
    # the dialect: what is drawn and played here is then what the machine will
    # do, including anything odd about it.
    #
    # Without the core checkout the editor still opens tunes -- it just cannot
    # say anything about them.
    module Engine
      RELATIVE_PATH = 'fmruby-core/lib/add/picoruby-midi-mml/mrblib/midi_mml.rb'

      # A quarter note. The parser's unit; the tempo is not the parser's
      # business (see Tune).
      CLOCKS_PER_QUARTER = 24

      module_function

      def path
        @path ||= find_parser
      end

      def available?
        !path.nil? && load_parser
      end

      def unavailable_reason
        return nil if available?
        return "#{RELATIVE_PATH} not found next to the editor" if path.nil?

        @load_error || 'the parser could not be loaded'
      end

      # [{type:, clock:, note:, velocity:, channel:, duration_clocks:}, ...]
      # and the length in clocks. Returns nil when the parser is unavailable.
      def parse(mml, channel: 0, velocity: 100)
        return nil unless available?

        sequence = ::MIDI::MML::Sequence.new(mml, channel: channel, velocity: velocity)
        [sequence.events, sequence.total_length]
      rescue StandardError => e
        @load_error = e.message
        nil
      end

      # The GM instrument names, from the same checkout, so a program number in
      # a tune can be shown as what it will play on an external instrument.
      GM_RELATIVE_PATH = 'fmruby-core/lib/add/picoruby-fmrb-midi/mrblib/fmrb-gm.rb'

      def gm_name(program)
        return nil if program.nil?
        return nil unless load_gm_names

        ::FmrbMidi::GM_NAMES[program]
      end

      def load_gm_names
        return @gm_loaded if defined?(@gm_loaded)

        file = gm_path
        @gm_loaded =
          if file.nil?
            false
          else
            begin
              load file
              true
            rescue StandardError, ScriptError
              false
            end
          end
      end

      def gm_path
        return nil if path.nil?

        candidate = path.sub(RELATIVE_PATH, GM_RELATIVE_PATH)
        File.file?(candidate) ? candidate : nil
      end

      def load_parser
        return true if defined?(::MIDI::MML::Sequence)

        # The file expects the namespace to exist, as it does on the device.
        Object.const_set(:MIDI, Module.new) unless Object.const_defined?(:MIDI)
        load path
        true
      rescue StandardError, ScriptError => e
        @load_error = e.message
        false
      end

      # Walk up from the editor to whichever checkout holds fmruby-core, so the
      # tool works from a worktree as well as from the main tree.
      def find_parser
        directory = __dir__
        6.times do
          candidate = File.join(directory, RELATIVE_PATH)
          return candidate if File.file?(candidate)

          parent = File.dirname(directory)
          break if parent == directory

          directory = parent
        end
        nil
      end
    end
  end
end

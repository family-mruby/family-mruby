# frozen_string_literal: true

module FmAssetEditor
  module Formats
    # Tunes for FmrbMidi::MmlPlayer, written as text.
    #
    # The dialect inside a part is whatever MIDI::MML::Sequence parses -- the
    # editor borrows that very parser rather than describing it again (see
    # Mml::Engine). What this format adds is the little the dialect has no room
    # for: the tempo, whether to repeat, how loud, and where one part ends and
    # the next begins.
    module MmlTune
      LABEL = 'MML tune (text, one part per line)'
      EXTENSIONS = ['.mml'].freeze
      TEMPLATE = <<~MML
        # a tune for FmrbMidi::MmlPlayer
        bpm 120
        loop off

        # what plays the parts below (all four may be left out):
        #   voice pulse1 | pulse2 | triangle | noise
        #   duty 0-3      pulse width, 12.5 / 25 / 50 / 75 per cent
        #   volume 0-127  channel volume
        #   program 0-127 GM instrument, for an external sound source
        o4 l8 crdrerfrgrarbr>cr
      MML

      module_function

      def label
        LABEL
      end

      def extensions
        EXTENSIONS
      end

      def view
        :mml
      end

      def detect?(path)
        File.extname(path).downcase == '.mml'
      end

      def load(path)
        Mml::Document.new(format: self, path: path, text: File.read(path))
      end

      def blank
        Mml::Document.new(format: self, path: nil, text: TEMPLATE)
      end

      def write(document, path)
        text = document.text
        text += "\n" unless text.empty? || text.end_with?("\n")
        File.write(path, text)
      end
    end
  end
end

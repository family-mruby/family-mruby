# frozen_string_literal: true

module FmAssetEditor
  module Mml
    # An open .mml file. The text is what is saved; everything else is read
    # from it, so there is one copy of the truth and no way for the two to
    # drift apart.
    class Document
      attr_reader :format, :text
      attr_accessor :path

      def initialize(format:, path:, text:)
        @format = format
        @path = path
        @text = text
        @saved_text = text
        @tune = nil
      end

      def name
        @path ? File.basename(@path) : 'untitled.mml'
      end

      def text=(value)
        value = value.to_s
        return if value == @text

        @text = value
        @tune = nil
      end

      def tune
        @tune ||= Tune.new(@text)
      end

      # Change one setting line without disturbing the rest of the file.
      def set_setting(key, value)
        self.text = Tune.with_setting(@text, key, value)
      end

      def dirty?
        @text != @saved_text
      end

      def save(path = @path)
        raise ArgumentError, 'no path to save to' if path.nil?

        @format.write(self, path)
        @path = path
        @saved_text = @text
        path
      end
    end
  end
end

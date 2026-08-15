# frozen_string_literal: true

module FmAssetEditor
  # Registry of asset kinds.
  #
  # Only the two BMP flavours exist today, but everything above this line is
  # written against this interface so another asset type (a tile map, a palette
  # file, a font in text form, ...) can be added without touching the window.
  # A format is any object answering:
  #
  #   label            name shown in the UI
  #   extensions       file name suffixes worth offering in the open dialog
  #   detect?(path)    true when this format owns the file
  #   load(path)       -> Document
  #   write(doc, path)
  #   view             which editor view the window should host (:grid so far)
  #
  # A :grid format additionally answers:
  #
  #   swatches(doc)    -> [[value, [r, g, b] or nil, label], ...] for the palette pane
  #   color(doc, v)    -> [r, g, b], or nil when the value means "transparent"
  #   value_label(v)   -> text for the status line
  #   default_value    -> value a fresh document paints with
  #   cell             -> guide grid step in pixels, or nil
  #
  # Registration order is match order, so put narrow formats before broad ones.
  module Format
    module_function

    def registry
      @registry ||= []
    end

    def register(format)
      registry << format unless registry.include?(format)
      format
    end

    def all
      registry.dup
    end

    def find(path)
      registry.find { |format| format.detect?(path) }
    end

    def find!(path)
      find(path) or raise Bmp::Error, "#{File.basename(path)}: no editor knows this file"
    end

    def by_label(label)
      registry.find { |format| format.label == label }
    end
  end
end

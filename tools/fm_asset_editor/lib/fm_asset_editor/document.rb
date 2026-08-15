# frozen_string_literal: true

module FmAssetEditor
  # One open asset: a grid of byte values plus undo history.
  #
  # What a value means is up to the format (a colour for sprites, a palette
  # index for the BASIC sheets), so nothing here interprets it.
  class Document
    UNDO_LIMIT = 200

    attr_reader :format, :width, :height, :pixels, :meta
    attr_accessor :path

    # meta carries whatever the format wants to hand back to its writer
    # untouched -- the stored palette of a BMP, for instance, so that opening
    # and saving a file does not rewrite bytes the editor never showed.
    def initialize(format:, path:, width:, height:, pixels:, meta: {})
      @format = format
      @path = path
      @width = width
      @height = height
      @pixels = pixels
      @meta = meta
      @meta_dirty = false
      @stroke = nil
      @undo = []
      @redo = []
      @saved_depth = 0
    end

    # For edits that are not pixels (a format setting, say) and so have no undo
    # entry of their own, but still have to be saved.
    def touch_meta
      @meta_dirty = true
    end

    def name
      @path ? File.basename(@path) : 'untitled'
    end

    def inside?(x, y)
      x >= 0 && y >= 0 && x < @width && y < @height
    end

    def get(x, y)
      return nil unless inside?(x, y)

      @pixels[y * @width + x]
    end

    # Edits are collected into a stroke until commit_stroke, so one drag undoes
    # in one step.
    def set(x, y, value)
      return false unless inside?(x, y)

      index = y * @width + x
      old = @pixels[index]
      return false if old == value

      (@stroke ||= []) << [index, old]
      @pixels[index] = value
      true
    end

    def fill(x, y, value)
      return false unless inside?(x, y)

      target = get(x, y)
      return false if target == value

      stack = [[x, y]]
      until stack.empty?
        cx, cy = stack.pop
        next unless inside?(cx, cy)
        next unless @pixels[cy * @width + cx] == target

        set(cx, cy, value)
        stack.push([cx + 1, cy], [cx - 1, cy], [cx, cy + 1], [cx, cy - 1])
      end
      true
    end

    def commit_stroke
      return false if @stroke.nil? || @stroke.empty?

      # uniq keeps the first entry per pixel, which is the value before the
      # stroke started -- the one undo has to restore.
      @undo << @stroke.uniq { |index, _| index }
      @undo.shift while @undo.size > UNDO_LIMIT
      @redo.clear
      @stroke = nil
      true
    end

    def undo
      return false if @undo.empty?

      @redo << apply(@undo.pop)
      true
    end

    def redo
      return false if @redo.empty?

      @undo << apply(@redo.pop)
      true
    end

    def undo?
      !@undo.empty?
    end

    def redo?
      !@redo.empty?
    end

    def dirty?
      @meta_dirty || @undo.size != @saved_depth
    end

    def save(path = @path)
      raise ArgumentError, 'no path to save to' if path.nil?

      @format.write(self, path)
      @path = path
      @saved_depth = @undo.size
      @meta_dirty = false
      path
    end

    private

    def apply(stroke)
      inverse = stroke.map { |index, _| [index, @pixels[index]] }
      stroke.each { |index, value| @pixels[index] = value }
      inverse
    end
  end
end

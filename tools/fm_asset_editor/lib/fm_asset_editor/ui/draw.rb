# frozen_string_literal: true

require 'fiddle'

module FmAssetEditor
  module Ui
    # Thin wrapper over the raw libui drawing calls.
    #
    # The declarative glimmer path DSL builds a proxy object per shape, which
    # costs about 4 seconds for a 128x128 grid. Batching the rectangles that
    # share a colour into one raw path brings the same drawing down to ~30 ms,
    # so all drawing here goes straight to libui.
    module Draw
      SOLID = 0        # uiDrawBrushTypeSolid
      WINDING = 0      # uiDrawFillModeWinding

      module_function

      def brush(rgb)
        brush = ::LibUI::FFI::DrawBrush.malloc(Fiddle::RUBY_FREE)
        brush.Type = SOLID
        brush.R = rgb[0] / 255.0
        brush.G = rgb[1] / 255.0
        brush.B = rgb[2] / 255.0
        brush.A = 1.0
        brush
      end

      # rects: Array of [x, y, width, height]
      def fill_rects(context, rects, rgb)
        return if rects.nil? || rects.empty?

        path = ::LibUI.draw_new_path(WINDING)
        rects.each { |x, y, width, height| ::LibUI.draw_path_add_rectangle(path, x, y, width, height) }
        ::LibUI.draw_path_end(path)
        ::LibUI.draw_fill(context, path, brush(rgb))
        ::LibUI.draw_free_path(path)
      end

      def fill_rect(context, x, y, width, height, rgb)
        fill_rects(context, [[x, y, width, height]], rgb)
      end

      # A line of text at (x, y), where y is the top of the line.
      def text(context, x, y, string, rgb, size: 11.0, family: 'Monospace')
        string = string.to_s
        return if string.empty?

        attributed = ::LibUI.new_attributed_string(string)
        color = ::LibUI.new_color_attribute(rgb[0] / 255.0, rgb[1] / 255.0, rgb[2] / 255.0, 1.0)
        ::LibUI.attributed_string_set_attribute(attributed, color, 0, string.bytesize)

        font = ::LibUI::FFI::FontDescriptor.malloc
        font.Family = family
        font.Size = size
        font.Weight = 400 # normal
        font.Italic = 0
        font.Stretch = 4 # normal

        params = ::LibUI::FFI::DrawTextLayoutParams.malloc
        params.String = attributed
        params.DefaultFont = font
        params.Width = 1000 # no wrapping wanted
        params.Align = 0

        layout = ::LibUI.draw_new_text_layout(params)
        ::LibUI.draw_text(context, layout, x, y)
        ::LibUI.draw_free_text_layout(layout)
        ::LibUI.free_attributed_string(attributed)
      end

      # Rectangle outline drawn as four filled bars, so no stroke parameters
      # have to be allocated.
      def outline(context, x, y, width, height, rgb, thickness = 1)
        fill_rects(context,
                   [[x, y, width, thickness],
                    [x, y + height - thickness, width, thickness],
                    [x, y, thickness, height],
                    [x + width - thickness, y, thickness, height]],
                   rgb)
      end
    end
  end
end

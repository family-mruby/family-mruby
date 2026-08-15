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

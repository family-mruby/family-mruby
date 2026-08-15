# frozen_string_literal: true

# Family mruby asset editor.
#
# The parts below the UI (bmp, rgb332, document, formats) use nothing but the
# standard library, so they can be required from other tools and from tests
# without a display or the GUI gem.
require_relative 'fm_asset_editor/bmp'
require_relative 'fm_asset_editor/rgb332'
require_relative 'fm_asset_editor/document'
require_relative 'fm_asset_editor/format'
require_relative 'fm_asset_editor/formats/basic_sheet'
require_relative 'fm_asset_editor/formats/sprite332'

module FmAssetEditor
  # Narrow formats first: Sprite332 accepts any 8bpp BMP, so it has to come last.
  Format.register(Formats::BasicSheet)
  Format.register(Formats::Sprite332)

  # Load the window only when it is actually needed, so the file handling above
  # stays usable where libui is not installed.
  def self.require_ui
    require 'glimmer-dsl-libui'
    require_relative 'fm_asset_editor/ui/draw'
    require_relative 'fm_asset_editor/ui/grid_view'
    require_relative 'fm_asset_editor/ui/palette_view'
    require_relative 'fm_asset_editor/ui/main_window'
  rescue LoadError => e
    raise LoadError, <<~MESSAGE
      #{e.message}

      The editor window needs the glimmer-dsl-libui gem:

          gem install glimmer-dsl-libui

      It ships its own libui build, so nothing else has to be installed. A
      display is required as well; under WSL2 that is WSLg, which is on by
      default (echo $DISPLAY should print something).
    MESSAGE
  end
end

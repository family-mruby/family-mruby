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
require_relative 'fm_asset_editor/settings'
require_relative 'fm_asset_editor/formats/basic_sheet'
require_relative 'fm_asset_editor/formats/sprite332'

module FmAssetEditor
  # Narrow formats first: Sprite332 accepts any 8bpp BMP, so it has to come last.
  Format.register(Formats::BasicSheet)
  Format.register(Formats::Sprite332)

  # Load the window only when it is actually needed, so the file handling above
  # stays usable where libui is not installed.
  def self.require_ui
    quiet_gsettings
    require 'glimmer-dsl-libui'
    require_relative 'fm_asset_editor/ui/draw'
    require_relative 'fm_asset_editor/ui/file_dialog'
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

  # GTK stores its own file chooser state through GSettings, whose default
  # backend is dconf, which talks over the session bus. Under WSL2 the bus
  # address is exported but nothing is listening on it, so every one of those
  # writes prints
  #
  #   dconf-WARNING **: failed to commit changes to dconf: Could not connect
  #
  # and one dialog produces a couple of dozen lines. Where the bus is
  # demonstrably absent, ask GSettings for the memory backend instead: the only
  # thing lost is GTK's own memory of the chooser, and the folders that matter
  # are remembered by Settings rather than by GTK. An explicit GSETTINGS_BACKEND
  # is left alone.
  def self.quiet_gsettings
    return if ENV.key?('GSETTINGS_BACKEND')
    return if session_bus_reachable?

    ENV['GSETTINGS_BACKEND'] = 'memory'
  end

  def self.session_bus_reachable?
    address = ENV['DBUS_SESSION_BUS_ADDRESS'].to_s
    return false if address.empty?
    # Abstract sockets cannot be looked at, so they are taken at face value.
    return true unless address.include?('unix:path=')

    path = address[/unix:path=([^,]+)/, 1]
    path.nil? || File.socket?(path)
  end
end

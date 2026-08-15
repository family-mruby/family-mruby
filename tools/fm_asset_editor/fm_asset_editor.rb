#!/usr/bin/env ruby
# frozen_string_literal: true

# Desktop editor for the artwork that ships in flash/: sprites, icons and the
# FMRuby BASIC character sheets.
#
# The point of a dedicated editor is that these BMPs do not mean what a general
# image editor thinks they mean. In a sprite the pixel byte *is* the RGB332
# colour the machine shows (the loader never reads the file palette), and in a
# BASIC sheet it is a palette index of 0..3. A general editor is free to
# renumber indices or promote the file to 24bpp on save, either of which
# silently breaks the asset.
#
# Usage:
#   ruby tools/fm_asset_editor/fm_asset_editor.rb [FILE]
#   ruby tools/fm_asset_editor/fm_asset_editor.rb --new 16x16
#   ruby tools/fm_asset_editor/fm_asset_editor.rb --formats
#
# Needs the glimmer-dsl-libui gem (gem install glimmer-dsl-libui) and a display;
# under WSL2 that is WSLg, which is on by default.

require_relative 'lib/fm_asset_editor'

def usage
  warn <<~USAGE
    usage: fm_asset_editor.rb [FILE]
           fm_asset_editor.rb --new WxH   start with an empty sprite
           fm_asset_editor.rb --new mml   start with an empty tune
           fm_asset_editor.rb --formats   list what the editor understands
  USAGE
  exit 1
end

path = nil
new_size = nil

until ARGV.empty?
  arg = ARGV.shift
  case arg
  when '--formats'
    FmAssetEditor::Format.all.each { |format| puts "#{format.label}  #{format.extensions.join(' ')}" }
    exit 0
  when '--new'
    new_size = ARGV.shift or usage
  when '-h', '--help'
    usage
  else
    usage if path
    path = arg
  end
end

document =
  if new_size == 'mml'
    FmAssetEditor::Formats::MmlTune.blank
  elsif new_size
    width, height = new_size.split(/[x*]/).map(&:to_i)
    usage if width.to_i < 1 || height.to_i < 1
    FmAssetEditor::Formats::Sprite332.blank(width, height)
  elsif path
    abort "#{path}: no such file" unless File.file?(path)

    format = FmAssetEditor::Format.find(path)
    abort "#{path}: no editor knows this file (try --formats)" if format.nil?

    begin
      format.load(path)
    rescue FmAssetEditor::Bmp::Error => e
      abort e.message
    end
  else
    FmAssetEditor::Formats::Sprite332.blank(16, 16)
  end

FmAssetEditor.require_ui
FmAssetEditor::Ui::MainWindow.new(document).show

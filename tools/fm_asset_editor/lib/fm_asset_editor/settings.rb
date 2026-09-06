# frozen_string_literal: true

require 'json'
require 'fileutils'

module FmAssetEditor
  # The little the editor remembers between runs: which folder each file dialog
  # should start in, and what the right mouse button does on the canvas. Kept
  # deliberately small; anything that belongs to a file belongs in the file.
  class Settings
    KINDS = %i[open save].freeze
    RIGHT_BUTTONS = %i[pick erase].freeze
    DEFAULT_RIGHT_BUTTON = :pick

    def self.default_path
      base = ENV['XDG_CONFIG_HOME']
      base = File.join(Dir.home, '.config') if base.nil? || base.empty?
      File.join(base, 'fm_asset_editor', 'state.json')
    end

    def initialize(path = self.class.default_path)
      @path = path
      @data = read
    end

    # nil when nothing is remembered, or when the folder has since gone away.
    def directory(kind)
      directory = @data[key(kind)]
      directory if directory.is_a?(String) && File.directory?(directory)
    end

    def remember(kind, directory)
      return unless directory && File.directory?(directory)

      directory = File.expand_path(directory)
      return if @data[key(kind)] == directory

      @data[key(kind)] = directory
      write
    end

    # :pick (the default) or :erase. Anything else in the file reads as the
    # default, so an old or hand-edited file cannot leave the button dead.
    def right_button
      value = @data['right_button']
      value = value.to_sym if value.is_a?(String)
      RIGHT_BUTTONS.include?(value) ? value : DEFAULT_RIGHT_BUTTON
    end

    def right_button=(value)
      raise ArgumentError, "unknown right button action #{value}" unless RIGHT_BUTTONS.include?(value)
      return if right_button == value

      @data['right_button'] = value.to_s
      write
    end

    private

    def key(kind)
      raise ArgumentError, "unknown dialog #{kind}" unless KINDS.include?(kind)

      "#{kind}_directory"
    end

    # A missing or damaged state file is not worth a word to the user: the
    # editor simply starts without a memory.
    def read
      JSON.parse(File.read(@path)).tap { |data| return {} unless data.is_a?(Hash) }
    rescue StandardError
      {}
    end

    def write
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, "#{JSON.pretty_generate(@data)}\n")
    rescue StandardError
      nil
    end
  end
end

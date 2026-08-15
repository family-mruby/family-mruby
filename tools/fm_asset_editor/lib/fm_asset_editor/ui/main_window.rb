# frozen_string_literal: true

module FmAssetEditor
  module Ui
    # The editor window.
    #
    # It holds one pane per kind of asset -- a canvas with a palette for the
    # bitmaps, a text pane with a piano roll for the tunes -- and shows the one
    # the open file asks for (Format#view). Both keep their document, so
    # opening a tune and going back to a sprite finds it as it was left.
    class MainWindow
      include Glimmer

      TOOLS = { 'Pen' => :pen, 'Fill' => :fill, 'Pick' => :pick }.freeze
      BUTTON_LEFT = 1
      BUTTON_RIGHT = 3
      HELD_LEFT = 0x01 # Held1To64 is a bitmask, bit n-1 for button n

      # choose: true opens on the chooser instead of on the (empty) document,
      # which is what starting the editor with no file to open should do.
      def initialize(document, settings = Settings.new, choose: false)
        @document = document
        @settings = settings
        @mode = choose ? :start : document.format.view
        @grid_document = grid?(document) ? document : Formats::Sprite332.blank(16, 16)
        @mml_document = mml?(document) ? document : Formats::MmlTune.blank
        @grid = GridView.new(@grid_document)
        @palette = PaletteView.new(@grid_document)
        @roll = MmlRoll.new(@mml_document.tune)
        @playback = Mml::Playback.new
        @tool = :pen
        @painting = false
        @hover = nil
        @syncing = false
        build
        sync_color_inputs
        show_pane
        refresh_problems
        refresh_labels
        refresh_time
      end

      def show
        @window.show
      end

      private

      def build
        build_menus
        @window = window(title, 1024, 820) {
          margined true

          horizontal_box {
            @grid_body = vertical_box {
              @canvas = scrolling_area(@grid.width, @grid.height) {
                on_draw do |params|
                  @grid.draw(params[:context], params)
                end
                on_mouse_event do |event|
                  handle_canvas_mouse(event)
                end
                on_mouse_exit do
                  @hover = nil
                  @grid.cursor = nil
                  refresh_status
                  @canvas.queue_redraw_all
                end
                on_key_event do |event|
                  handle_key(event)
                end
              }
            }

            # Shown when the editor is started with nothing to open, and from
            # File > New. It is a pane like the others rather than a window of
            # its own: one window, one place to look.
            @start_body = vertical_box {
              label('What would you like to make?') { stretchy false }
              horizontal_box {
                stretchy false
                label('Sprite') { stretchy false }
                @new_width_spinbox = spinbox(1, Bmp::MAX_SIDE) { value 16 }
                label('x') { stretchy false }
                @new_height_spinbox = spinbox(1, Bmp::MAX_SIDE) { value 16 }
                button('Create') {
                  on_clicked do
                    adopt(Formats::Sprite332.blank(@new_width_spinbox.value, @new_height_spinbox.value))
                  end
                }
              }
              button('BASIC character sheet (128x128)') {
                stretchy false
                on_clicked { adopt(Formats::BasicSheet.blank) }
              }
              button('MML tune') {
                stretchy false
                on_clicked { adopt(Formats::MmlTune.blank) }
              }
              button('Open a file...') {
                stretchy false
                on_clicked { open_dialog }
              }
              label('') # takes the space left over, so the buttons stay at the top
            }

            @mml_body = vertical_box {
              @mml_entry = non_wrapping_multiline_entry {
                text @mml_document.text
                on_changed do |entry|
                  next if @syncing_text

                  @mml_document.text = entry.text
                  refresh_tune
                end
              }
              @roll_area = area {
                on_draw do |params|
                  @roll_width = params[:area_width]
                  @roll.draw(params[:context], params[:area_width], params[:area_height])
                end
                on_mouse_down do |event|
                  @seek_was_playing = @playback.playing?
                  @playback.stop if @seek_was_playing
                  seek_to(event[:x])
                end
                on_mouse_drag do |event|
                  seek_to(event[:x])
                end
                on_mouse_up do
                  play_tune if @seek_was_playing
                  @seek_was_playing = false
                end
              }
            }

            vertical_box {
              stretchy false

              group('Asset') {
                stretchy false
                vertical_box {
                  @format_label = label('')
                  @size_label = label('')
                  @path_label = label('')
                  @note_label = label('')
                }
              }

              @grid_controls = vertical_box {
                group('Tool') {
                  stretchy false
                  vertical_box {
                    radio_buttons {
                      items TOOLS.keys
                      selected 0
                      on_selected do |radio|
                        @tool = TOOLS.values[radio.selected]
                      end
                    }
                  }
                }

                group('View') {
                  stretchy false
                  vertical_box {
                    horizontal_box {
                      stretchy false
                      label('Zoom') { stretchy false }
                      @zoom_spinbox = spinbox(GridView::MIN_ZOOM, GridView::MAX_ZOOM) {
                        value @grid.zoom
                        on_changed do |spinbox|
                          set_zoom(spinbox.value)
                        end
                      }
                      label('Guide') { stretchy false }
                      @guide_spinbox = spinbox(0, 64) {
                        value @grid.cell.to_i
                        on_changed do |spinbox|
                          @grid.cell_override = spinbox.value.zero? ? nil : spinbox.value
                          @canvas.queue_redraw_all
                        end
                      }
                    }
                    checkbox('Pixel grid') {
                      stretchy false
                      checked @grid.show_grid
                      on_toggled do |box|
                        @grid.show_grid = box.checked?
                        @canvas.queue_redraw_all
                      end
                    }
                  }
                }

                # The palette group is the only stretchy child of the panel, so
                # it takes whatever height is left; the view lays all 256
                # swatches out in that space rather than scrolling.
                group('Colour') {
                  vertical_box {
                    @palette_area = area {
                      on_draw do |params|
                        @palette.draw(params[:context], params[:area_width], params[:area_height])
                      end
                      on_mouse_down do |event|
                        value = @palette.value_at(event[:x], event[:y])
                        select_value(value) unless value.nil?
                      end
                    }

                    horizontal_box {
                      stretchy false
                      label('R') { stretchy false }
                      @red_spinbox = spinbox(0, 7) {
                        on_changed { levels_changed }
                      }
                      label('G') { stretchy false }
                      @green_spinbox = spinbox(0, 7) {
                        on_changed { levels_changed }
                      }
                      label('B') { stretchy false }
                      @blue_spinbox = spinbox(0, 3) {
                        on_changed { levels_changed }
                      }
                    }

                    horizontal_box {
                      stretchy false
                      label('Hex') { stretchy false }
                      @hex_entry = entry {
                        on_changed { hex_changed }
                      }
                    }

                    @selected_label = label('') { stretchy false }
                  }
                }
              }

              @mml_controls = vertical_box {
                group('Tune') {
                  stretchy false
                  vertical_box {
                    horizontal_box {
                      stretchy false
                      label('BPM') { stretchy false }
                      @bpm_spinbox = spinbox(Mml::Tune::BPM_RANGE.first, Mml::Tune::BPM_RANGE.last) {
                        value @mml_document.tune.bpm
                        on_changed do |spinbox|
                          next if @syncing_text

                          @mml_document.set_setting('bpm', spinbox.value)
                          sync_mml_text
                        end
                      }
                      @loop_checkbox = checkbox('Loop') {
                        stretchy false
                        checked @mml_document.tune.loop?
                        on_toggled do |box|
                          next if @syncing_text

                          @mml_document.set_setting('loop', box.checked? ? 'on' : 'off')
                          sync_mml_text
                        end
                      }
                    }
                    horizontal_box {
                      stretchy false
                      button('Play') { on_clicked { play_tune } }
                      button('Stop') { on_clicked { stop_tune } }
                      button('Export WAV...') { on_clicked { export_wav } }
                    }
                    @time_label = label('') { stretchy false }
                  }
                }

                group('Notes') {
                  vertical_box {
                    @problem_entry = non_wrapping_multiline_entry {
                      read_only true
                    }
                  }
                }
              }

              @status_label = label('') { stretchy false }
            }
          }
        }
      end

      def build_menus
        menu('File') {
          menu_item('New...') {
            on_clicked { choose_asset }
          }
          menu_item('Open...') {
            on_clicked { open_dialog }
          }
          menu_item('Save') {
            on_clicked { save }
          }
          menu_item('Save As...') {
            on_clicked { save_as }
          }
          separator_menu_item
          menu_item('Quit') {
            on_clicked { quit }
          }
        }
        menu('Edit') {
          menu_item('Undo') {
            on_clicked { undo }
          }
          menu_item('Redo') {
            on_clicked { redo_edit }
          }
          separator_menu_item
          menu_item('Normalise Palette (RGB332)') {
            on_clicked { normalise_palette }
          }
        }
        menu('View') {
          menu_item('Zoom In') {
            on_clicked { set_zoom(@grid.zoom + 1) }
          }
          menu_item('Zoom Out') {
            on_clicked { set_zoom(@grid.zoom - 1) }
          }
        }
        menu('Help') {
          menu_item('Formats') {
            on_clicked { show_format_help }
          }
          menu_item('Keys') {
            on_clicked { show_key_help }
          }
        }
      end

      # --- editing -------------------------------------------------------

      def handle_canvas_mouse(event)
        pixel = @grid.pixel_at(event[:x], event[:y])
        if pixel != @hover
          @hover = pixel
          @grid.cursor = pixel
          refresh_status
          @canvas.queue_redraw_all
        end

        if event[:down] == BUTTON_LEFT
          @painting = true
          paint(pixel, primary: true)
        elsif event[:down] == BUTTON_RIGHT
          @painting = true
          paint(pixel, primary: false)
        elsif event[:up].positive?
          @painting = false
          @document.commit_stroke
          refresh_labels
        elsif @painting && event[:held].positive? && @tool == :pen
          paint(pixel, primary: (event[:held] & HELD_LEFT).positive?)
        end
      end

      def paint(pixel, primary:)
        return if pixel.nil?

        x, y = pixel
        case @tool
        when :pick
          select_value(@document.get(x, y))
          return
        when :fill
          changed = @document.fill(x, y, paint_value(primary))
        else
          changed = @document.set(x, y, paint_value(primary))
        end
        return unless changed

        @canvas.queue_redraw_all
        refresh_labels
      end

      # The right button erases: to transparent where the format has one, to the
      # background index otherwise.
      def paint_value(primary)
        primary ? @palette.selected : @document.format.erase_value
      end

      # --- colour selection ----------------------------------------------
      #
      # The palette, the R/G/B spinboxes and the hex entry are three views of
      # one value. Whichever is used, the others follow; source names the one
      # the user is typing in, which is left alone so the caret does not jump.

      def select_value(value, source: nil)
        return if value.nil?

        @palette.select(value)
        sync_color_inputs(source)
        @palette_area.queue_redraw_all
        refresh_labels
      end

      def levels_changed
        return if @syncing || !numeric_input?

        select_value(@document.format.from_levels(@red_spinbox.value, @green_spinbox.value,
                                                  @blue_spinbox.value),
                     source: :levels)
      end

      def hex_changed
        return if @syncing || !numeric_input?

        value = @document.format.parse_color(@hex_entry.text)
        select_value(value, source: :hex) unless value.nil?
      end

      # True when the format can name a colour by numbers, not just by index.
      def numeric_input?
        @document.format.respond_to?(:levels)
      end

      def sync_color_inputs(source = nil)
        enabled = numeric_input?
        [@red_spinbox, @green_spinbox, @blue_spinbox, @hex_entry].each { |control| control.enabled = enabled }
        return unless enabled

        @syncing = true
        begin
          value = @palette.selected
          unless source == :levels
            red, green, blue = @document.format.levels(value)
            @red_spinbox.value = red
            @green_spinbox.value = green
            @blue_spinbox.value = blue
          end
          @hex_entry.text = format('%02X', value) unless source == :hex
        ensure
          @syncing = false
        end
      end

      def undo
        # The tune pane is a text box, which brings its own editing.
        return unless grid?
        return unless @document.undo

        @canvas.queue_redraw_all
        refresh_labels
      end

      def redo_edit
        return unless grid?
        return unless @document.redo

        @canvas.queue_redraw_all
        refresh_labels
      end

      def normalise_palette
        format = @document.format
        unless format.respond_to?(:normalise_palette)
          message_box('Normalise Palette', "#{format.label} has a fixed palette; nothing to normalise.")
          return
        end

        if format.normalise_palette(@document)
          refresh_labels
          message_box('Normalise Palette',
                      "The next save writes the canonical RGB332 palette, so the file will look\n" \
                      'in other viewers the way it looks on the machine.')
        else
          message_box('Normalise Palette', 'The palette is already the canonical RGB332 table.')
        end
      end

      def handle_key(event)
        return 0 if event[:up]

        key = event[:key]
        control = event[:modifiers].include?(:control)
        shift = event[:modifiers].include?(:shift)

        if control
          case key
          when 'z' then shift ? redo_edit : undo
          when 'y' then redo_edit
          when 's' then save
          when 'o' then open_dialog
          else return 0
          end
          return 1
        end

        case key
        when '+', '=' then set_zoom(@grid.zoom + 1)
        when '-' then set_zoom(@grid.zoom - 1)
        when 'g'
          @grid.show_grid = !@grid.show_grid
          @canvas.queue_redraw_all
        when '1' then @tool = :pen
        when '2' then @tool = :fill
        when '3' then @tool = :pick
        else return 0
        end
        1
      end

      # --- files ---------------------------------------------------------

      def open_dialog
        path = FileDialog.open(@window, directory: start_directory(:open))
        return if path.nil?

        @settings.remember(:open, File.dirname(path))
        open_path(path)
      end

      # Where a dialog should land: the folder it was last used in, else the one
      # holding the open file, else wherever the editor was started from. Open
      # and save are remembered apart, since reading and writing are often in
      # different places (usr/share/sprites and a scratch folder, say).
      def start_directory(kind)
        @settings.directory(kind) || document_directory || Dir.pwd
      end

      def document_directory
        return nil if @document.path.nil?

        directory = File.dirname(File.expand_path(@document.path))
        File.directory?(directory) ? directory : nil
      end

      def open_path(path)
        format = Format.find(path)
        if format.nil?
          error("#{File.basename(path)}: no editor knows this file")
          return
        end

        document = format.load(path)
        adopt(document)
      rescue StandardError => e
        error(e.message)
      end

      def adopt(document)
        @document = document
        @mode = document.format.view
        if grid?(document)
          @grid_document = document
          @grid.document = document
          @palette.document = document
          @canvas.set_size(@grid.width, @grid.height)
          @guide_spinbox.value = @grid.cell.to_i
          @canvas.queue_redraw_all
          @palette_area.queue_redraw_all
          sync_color_inputs
        else
          @mml_document = document
          sync_mml_text
        end
        @window.title = title
        show_pane
        refresh_labels
      end

      # --- panes -----------------------------------------------------------

      def grid?(document = @document)
        @mode != :start && document.format.view == :grid
      end

      def mml?(document = @document)
        @mode != :start && document.format.view == :mml
      end

      def show_pane
        @start_body.visible = @mode == :start
        @grid_body.visible = grid?
        @grid_controls.visible = grid?
        @mml_body.visible = mml?
        @mml_controls.visible = mml?
      end

      # Back to the chooser, without touching what is open: picking something
      # replaces it, closing the choice leaves it alone.
      def choose_asset
        @mode = :start
        show_pane
        refresh_labels
      end

      def save
        if @document.path.nil?
          save_as
          return
        end

        @document.save
        refresh_labels
      rescue StandardError => e
        error(e.message)
      end

      def save_as
        path = FileDialog.save(@window, directory: start_directory(:save), name: @document.name)
        return if path.nil?

        @document.save(path)
        @settings.remember(:save, File.dirname(path))
        @window.title = title
        refresh_labels
      rescue StandardError => e
        error(e.message)
      end

      def quit
        @playback.stop
        @window.destroy
        ::LibUI.quit
      end

      # --- chrome --------------------------------------------------------

      def title
        mark = @document.dirty? ? '*' : ''
        "#{mark}#{@document.name} - Family mruby asset editor"
      end

      def refresh_labels
        if @mode == :start
          @format_label.text = 'nothing open yet'
          @size_label.text = ' '
          @path_label.text = ' '
          @note_label.text = ' '
          @status_label.text = ' '
          @window.title = 'Family mruby asset editor'
          return
        end

        @format_label.text = @document.format.label
        @path_label.text = @document.path ? shorten(@document.path) : '(not saved yet)'
        @window.title = title
        if grid?
          @size_label.text = "#{@document.width} x #{@document.height}"
          @note_label.text = palette_note
          @selected_label.text = @document.format.value_label(@palette.selected)
        else
          tune = @mml_document.tune
          @size_label.text = "#{tune.part_count} part(s), #{tune.note_count} notes, " \
                             "#{format('%.1f', tune.seconds)}s"
          @note_label.text = Mml::Engine.available? ? ' ' : "no preview: #{Mml::Engine.unavailable_reason}"
        end
        refresh_status
      end

      def palette_note
        format = @document.format
        return ' ' unless format.respond_to?(:palette_mismatch?)

        format.palette_mismatch?(@document) ? 'stored palette: not RGB332 (viewers only)' : ' '
      end

      # --- the tune pane ---------------------------------------------------

      # Re-read the text after an edit: the roll, the counts and anything the
      # parser will quietly ignore.
      def refresh_tune
        @roll.tune = @mml_document.tune
        @seek_at = nil if @seek_at && @seek_at > @mml_document.tune.seconds
        @roll_area.queue_redraw_all
        refresh_labels
        refresh_problems
        refresh_time
      end

      # What plays each part, and then anything wrong with the file.
      def refresh_problems
        tune = @mml_document.tune
        lines = tune.parts.map do |part|
          text = "#{part.channel}: #{part.summary}"
          name = Mml::Engine.gm_name(part.program)
          text += " (#{name})" if name
          text
        end
        lines << '' unless lines.empty? || tune.problems.empty?
        lines += tune.problems.map do |problem|
          problem.line ? "line #{problem.line}: #{problem.message}" : problem.message
        end
        lines << "engine: #{Mml::Engine.unavailable_reason}" unless Mml::Engine.available?
        @problem_entry.text = lines.empty? ? "\n" : "#{lines.join("\n")}\n"
      end

      # Push the document's text into the pane without the change coming back
      # as an edit (the setting spinboxes rewrite a line of it).
      def sync_mml_text
        @syncing_text = true
        begin
          tune = @mml_document.tune
          @mml_entry.text = @mml_document.text
          @bpm_spinbox.value = tune.bpm
          @loop_checkbox.checked = tune.loop?
        ensure
          @syncing_text = false
        end
        refresh_tune
      end

      def play_tune(from = @seek_at || 0.0)
        return unless mml?

        problem = @playback.start(@mml_document.tune, from: from)
        return message_box('Play', problem) if problem

        follow_playback
      end

      def stop_tune
        @playback.stop
        @roll.position = @seek_at
        @roll_area.queue_redraw_all
        refresh_time
      end

      # A click or a drag on the roll moves the head. Sound only follows when
      # the button comes up: the tune was handed to the player as a whole, so
      # seeking means rendering and starting again, which is too much to do on
      # every step of a drag.
      def seek_to(x)
        return unless mml?

        seconds = @roll.seconds_at(x, @roll_width.to_i)
        return if seconds.nil?

        @seek_at = seconds
        @roll.position = seconds
        @roll_area.queue_redraw_all
        refresh_time
      end

      # Move the head along while the tune plays. The timer stops itself when
      # the player is done, so nothing runs while the window is idle.
      def follow_playback
        return if @following

        @following = true
        Glimmer::LibUI.timer(0.05) do
          if @playback.playing?
            @roll.position = @playback.position
            @roll_area.queue_redraw_all
            refresh_time
            true
          else
            @following = false
            @roll.position = @seek_at
            @roll_area.queue_redraw_all
            refresh_time
            false
          end
        end
      end

      def refresh_time
        return unless mml?

        total = @mml_document.tune.seconds
        at = @roll.position || @seek_at || 0.0
        @time_label.text = "#{clock(at)} / #{clock(total)}"
      end

      def clock(seconds)
        seconds = 0.0 if seconds.nil? || seconds.negative?
        format('%d:%04.1f', (seconds / 60).to_i, seconds % 60)
      end

      def export_wav
        return unless mml?

        name = @mml_document.name.sub(/\.mml\z/, '') + '.wav'
        path = FileDialog.save(@window, directory: start_directory(:save), name: name)
        return if path.nil?

        if Mml::Audio.write(@mml_document.tune, path).nil?
          message_box('Export WAV', 'the tune has no notes to write')
          return
        end
        @settings.remember(:save, File.dirname(path))
      end

      def refresh_status
        unless grid?
          tune = @mml_document.tune
          @status_label.text = "#{tune.bpm} BPM  #{tune.total_clocks} clocks" \
                               "#{tune.loop? ? '  looping' : ''}"
          return
        end

        if @hover.nil?
          @status_label.text = ' '
          return
        end

        x, y = @hover
        value = @document.get(x, y)
        text = +"(#{x}, #{y})  #{@document.format.value_label(value)}"
        if @document.format.respond_to?(:code_at)
          code = @document.format.code_at(x, y)
          text << format("  code %d (0x%02X)", code, code)
        end
        @status_label.text = text
      end

      def set_zoom(zoom)
        return unless grid?

        @grid.zoom = zoom
        @zoom_spinbox.value = @grid.zoom
        @canvas.set_size(@grid.width, @grid.height)
        @canvas.queue_redraw_all
      end

      def shorten(path)
        parts = path.split('/')
        parts.size > 3 ? ".../#{parts.last(3).join('/')}" : path
      end

      def error(message)
        message_box_error('Asset editor', message.to_s)
      end

      def show_format_help
        message_box('Formats', Format.all.map(&:label).join("\n\n"))
      end

      def show_key_help
        message_box('Keys', <<~KEYS)
          Left drag    paint with the selected colour
          Right click  erase (transparent, or index 0)
          1 / 2 / 3    pen / fill / pick
          + / -        zoom
          g            pixel grid on/off
          Ctrl+Z / Y   undo / redo
          Ctrl+S       save
          Ctrl+O       open
        KEYS
      end
    end
  end
end

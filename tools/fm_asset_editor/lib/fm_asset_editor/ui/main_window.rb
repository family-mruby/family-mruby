# frozen_string_literal: true

module FmAssetEditor
  module Ui
    # The editor window: canvas on the left, palette and controls on the right.
    class MainWindow
      include Glimmer

      TOOLS = { 'Pen' => :pen, 'Fill' => :fill, 'Pick' => :pick }.freeze
      BUTTON_LEFT = 1
      BUTTON_RIGHT = 3
      HELD_LEFT = 0x01 # Held1To64 is a bitmask, bit n-1 for button n

      def initialize(document)
        @document = document
        @grid = GridView.new(document)
        @palette = PaletteView.new(document)
        @tool = :pen
        @painting = false
        @hover = nil
        build
        refresh_labels
      end

      def show
        @window.show
      end

      private

      def build
        build_menus
        @window = window("#{title}", 960, 700) {
          margined true

          horizontal_box {
            vertical_box {
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

              group('Colour') {
                vertical_box {
                  @palette_area = scrolling_area(@palette.width, @palette.height) {
                    on_draw do |params|
                      @palette.draw(params[:context])
                    end
                    on_mouse_down do |event|
                      value = @palette.value_at(event[:x], event[:y])
                      next if value.nil?

                      @palette.select(value)
                      @palette_area.queue_redraw_all
                      refresh_labels
                    end
                  }
                  @selected_label = label('') { stretchy false }
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
                  }
                  horizontal_box {
                    stretchy false
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
                    checked @grid.show_grid
                    on_toggled do |box|
                      @grid.show_grid = box.checked?
                      @canvas.queue_redraw_all
                    end
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
          value = @document.get(x, y)
          @palette.select(value)
          @palette_area.queue_redraw_all
          refresh_labels
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

      def undo
        return unless @document.undo

        @canvas.queue_redraw_all
        refresh_labels
      end

      def redo_edit
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
        pointer = ::LibUI.open_file(@window.libui)
        return if pointer.nil? || (pointer.respond_to?(:null?) && pointer.null?)

        path = pointer.to_s
        return if path.empty?

        open_path(path)
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
        @grid.document = document
        @palette.document = document
        @canvas.set_size(@grid.width, @grid.height)
        @palette_area.set_size(@palette.width, @palette.height)
        @guide_spinbox.value = @grid.cell.to_i
        @window.title = title
        @canvas.queue_redraw_all
        @palette_area.queue_redraw_all
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
        pointer = ::LibUI.save_file(@window.libui)
        return if pointer.nil? || (pointer.respond_to?(:null?) && pointer.null?)

        path = pointer.to_s
        return if path.empty?

        @document.save(path)
        @window.title = title
        refresh_labels
      rescue StandardError => e
        error(e.message)
      end

      def quit
        @window.destroy
        ::LibUI.quit
      end

      # --- chrome --------------------------------------------------------

      def title
        mark = @document.dirty? ? '*' : ''
        "#{mark}#{@document.name} - Family mruby asset editor"
      end

      def refresh_labels
        @format_label.text = @document.format.label
        @size_label.text = "#{@document.width} x #{@document.height}"
        @path_label.text = @document.path ? shorten(@document.path) : '(not saved yet)'
        @note_label.text = palette_note
        @selected_label.text = @document.format.value_label(@palette.selected)
        @window.title = title
        refresh_status
      end

      def palette_note
        format = @document.format
        return ' ' unless format.respond_to?(:palette_mismatch?)

        format.palette_mismatch?(@document) ? 'stored palette: not RGB332 (viewers only)' : ' '
      end

      def refresh_status
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

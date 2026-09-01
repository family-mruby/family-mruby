# frozen_string_literal: true

require "glimmer-dsl-libui"

module FmSigEditor
  module Ui
    # The window: a list of members on the left, the doc comment of the
    # selected one on the right.
    #
    # The two things it is for are the two that go wrong silently. A summary
    # over the buffer is cut without a word, so the byte count is on screen
    # while it is typed; a code line wider than the help pane breaks mid-token,
    # so those lines are listed. Everything else is an ordinary text field.
    class MainWindow
      include Glimmer

      def initialize(sig_dir, core_dir)
        @sig_dir = sig_dir
        @core_dir = core_dir
        @files = Dir.glob(File.join(sig_dir, "*.rbs")).sort
        raise "no .rbs files in #{sig_dir}" if @files.empty?

        @file = SigFile.new(@files.first)
        @filter = ""
        @entry = nil
        @loading = false
        @filtered = @file.entries
        @rows = rows_for(@filtered)
        build
        show_file
      end

      def show
        @window.show
      end

      private

      def build
        @window = window("fm_sig_editor - #{@sig_dir}", 1180, 800) {
          margined true

          vertical_box {
            horizontal_box {
              stretchy false

              label("File") { stretchy false }
              @file_combo = combobox {
                stretchy false
                items @files.map { |f| File.basename(f) }
                selected 0
                on_selected do
                  next if @loading

                  @file = SigFile.new(@files[@file_combo.selected])
                  show_file
                end
              }
              label("Filter") { stretchy false }
              @filter_entry = entry {
                on_changed do
                  next if @loading

                  @filter = @filter_entry.text.to_s
                  refresh_rows
                end
              }
              @summary_label = label("") { stretchy false }
            }

            horizontal_box {
              vertical_box {
                @table = table {
                  text_column("Member")
                  text_column("Bytes")
                  text_column("Long")
                  cell_rows @rows
                  selection_mode :zero_or_one
                  on_selection_changed do |_t, selection, _added, _removed|
                    select_row(selection)
                  end
                }
              }

              vertical_box {
                @signature_label = label("") { stretchy false }

                label("Summary -- one line, both languages, #{DocComment::SUMMARY_MAX_BYTES} bytes") {
                  stretchy false
                }
                horizontal_box {
                  stretchy false
                  label("ja") { stretchy false }
                  @summary_ja = entry { on_changed { collect } }
                }
                horizontal_box {
                  stretchy false
                  label("en") { stretchy false }
                  @summary_en = entry { on_changed { collect } }
                }
                @bytes_label = label("") { stretchy false }

                label("Long help (F1) -- ja") { stretchy false }
                @long_ja = non_wrapping_multiline_entry { on_changed { collect } }
                label("Long help (F1) -- en") { stretchy false }
                @long_en = non_wrapping_multiline_entry { on_changed { collect } }

                @warning_label = label("") { stretchy false }

                horizontal_box {
                  stretchy false
                  @save_button = button("Save") {
                    on_clicked { save }
                  }
                  button("Revert") {
                    on_clicked { show_entry(@entry_index) }
                  }
                  button("rake ti:help") {
                    on_clicked { run_help }
                  }
                }
              }
            }
          }
        }
      end

      def rows_for(entries)
        entries.map do |e|
          ["#{e.class_name}##{e.name}",
           e.doc.summary_over? ? "#{e.doc.summary_bytes} OVER" : e.doc.summary_bytes.to_s,
           e.doc.long? ? "yes" : ""]
        end
      end

      def show_file
        refresh_rows
        @summary_label.text = "#{@file.entries.size} documented members"
      end

      def refresh_rows
        list = @file.entries
        unless @filter.strip.empty?
          needle = @filter.strip.downcase
          list = list.select { |e| e.name.downcase.include?(needle) || e.class_name.downcase.include?(needle) }
        end
        @filtered = list
        @rows = rows_for(list)
        @table.cell_rows = @rows
        show_entry(0) unless list.empty?
      end

      def select_row(index)
        return if index.nil?

        show_entry(index)
      end

      def show_entry(index)
        entry = @filtered[index]
        return if entry.nil?

        @entry_index = index
        @entry = entry
        @loading = true
        @signature_label.text = "#{entry.class_name}##{entry.signature}"
        @summary_ja.text = entry.doc.summary_ja.to_s
        @summary_en.text = entry.doc.summary_en.to_s
        @long_ja.text = entry.doc.long_ja.to_s
        @long_en.text = entry.doc.long_en.to_s
        @loading = false
        refresh_measures
      end

      # Take what is on screen back into the entry, so Save writes what is seen.
      def collect
        return if @loading || @entry.nil?

        @entry.doc.summary_ja = @summary_ja.text.to_s
        @entry.doc.summary_en = @summary_en.text.to_s
        @entry.doc.long_ja = @long_ja.text.to_s
        @entry.doc.long_en = @long_en.text.to_s
        refresh_measures
      end

      def refresh_measures
        doc = @entry&.doc
        return if doc.nil?

        over = doc.summary_bytes - DocComment::SUMMARY_MAX_BYTES
        @bytes_label.text =
          if over.positive?
            "summary: #{doc.summary_bytes} bytes -- #{over} too many, the editor would cut it"
          else
            "summary: #{doc.summary_bytes} / #{DocComment::SUMMARY_MAX_BYTES} bytes"
          end

        wide = doc.wide_code_lines
        @warning_label.text =
          if wide.empty?
            doc.long? ? "long help: ok" : "long help: none"
          else
            "code lines wider than the help pane (#{DocComment::HELP_COLUMNS}): " +
              wide.map { |(line, text)| "line #{line} (#{text.length})" }.join(", ")
          end
      end

      def save
        return if @entry.nil?

        if @entry.doc.summary_over?
          msg_box_error(@window, "Summary too long",
                        "#{@entry.doc.summary_bytes} bytes. The editor keeps " \
                        "#{DocComment::SUMMARY_MAX_BYTES} and drops the rest without saying so, " \
                        "which is why this refuses to write it.")
          return
        end

        title = @entry.title
        @file.save(@entry)
        show_file
        @summary_label.text = "saved #{title}"
      end

      # The help files are generated, so a wording fix is only visible once
      # they are made again. Doing it here saves leaving the window.
      def run_help
        unless File.exist?(File.join(@core_dir, "Rakefile"))
          msg_box_error(@window, "No Rakefile", "Cannot find #{@core_dir}/Rakefile")
          return
        end

        output = `cd #{@core_dir.shellescape} && rake ti:help 2>&1`
        if $?.success?
          msg_box(@window, "rake ti:help", output.lines.last(3).join.strip)
        else
          msg_box_error(@window, "rake ti:help failed", output.lines.last(10).join)
        end
      end
    end
  end
end

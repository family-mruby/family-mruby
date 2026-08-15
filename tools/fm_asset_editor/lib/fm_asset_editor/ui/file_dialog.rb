# frozen_string_literal: true

require 'fiddle'

module FmAssetEditor
  module Ui
    # Open / save dialogs that start in a folder of our choosing.
    #
    # libui's uiOpenFile and uiSaveFile take no starting folder, and GTK then
    # opens on "Recently Used", which is the wrong place when the work is a tree
    # of asset folders. libui is linked against GTK here, so the dialog is built
    # through GTK itself: the native chooser's entry points are not variadic and
    # are therefore reachable with Fiddle. Where the library or its symbols are
    # missing (another platform, another libui build), this falls back to
    # libui's own dialog, which simply forgets the folder.
    module FileDialog
      ACTION_OPEN = 0
      ACTION_SAVE = 1
      RESPONSE_ACCEPT = -3

      module_function

      def open(window, directory: nil)
        return chooser(ACTION_OPEN, 'Open', '_Open', directory, nil) if gtk?

        from_libui(::LibUI.open_file(window.libui))
      end

      def save(window, directory: nil, name: nil)
        return chooser(ACTION_SAVE, 'Save As', '_Save', directory, name) if gtk?

        from_libui(::LibUI.save_file(window.libui))
      end

      def gtk?
        !gtk_functions.nil?
      end

      # nil once resolution has failed, so it is attempted only once.
      def gtk_functions
        return @gtk_functions if defined?(@gtk_functions)

        @gtk_functions = resolve_gtk
      end

      def resolve_gtk
        gtk = Fiddle.dlopen('libgtk-3.so.0')
        gobject = Fiddle.dlopen('libgobject-2.0.so.0')
        glib = Fiddle.dlopen('libglib-2.0.so.0')
        pointer = Fiddle::TYPE_VOIDP
        int = Fiddle::TYPE_INT
        void = Fiddle::TYPE_VOID
        {
          new: Fiddle::Function.new(gtk['gtk_file_chooser_native_new'],
                                    [pointer, pointer, int, pointer, pointer], pointer),
          set_folder: Fiddle::Function.new(gtk['gtk_file_chooser_set_current_folder'],
                                           [pointer, pointer], int),
          set_name: Fiddle::Function.new(gtk['gtk_file_chooser_set_current_name'],
                                         [pointer, pointer], void),
          set_overwrite: Fiddle::Function.new(gtk['gtk_file_chooser_set_do_overwrite_confirmation'],
                                              [pointer, int], void),
          run: Fiddle::Function.new(gtk['gtk_native_dialog_run'], [pointer], int),
          filename: Fiddle::Function.new(gtk['gtk_file_chooser_get_filename'], [pointer], pointer),
          unref: Fiddle::Function.new(gobject['g_object_unref'], [pointer], void),
          free: Fiddle::Function.new(glib['g_free'], [pointer], void)
        }
      rescue Fiddle::DLError, StandardError
        nil
      end

      def chooser(action, title, accept, directory, name)
        gtk = gtk_functions
        dialog = gtk[:new].call(title, nil, action, accept, '_Cancel')
        return nil if dialog.null?

        begin
          gtk[:set_folder].call(dialog, directory) if directory && File.directory?(directory)
          if name
            gtk[:set_name].call(dialog, name)
            gtk[:set_overwrite].call(dialog, 1)
          end
          return nil unless gtk[:run].call(dialog) == RESPONSE_ACCEPT

          filename = gtk[:filename].call(dialog)
          return nil if filename.null?

          path = filename.to_s
          gtk[:free].call(filename)
          path.empty? ? nil : path
        ensure
          gtk[:unref].call(dialog)
        end
      end

      def from_libui(result)
        return nil if result.nil?
        return nil if result.respond_to?(:null?) && result.null?

        path = result.to_s
        path.empty? ? nil : path
      end
    end
  end
end

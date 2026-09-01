#!/usr/bin/env ruby
# frozen_string_literal: true

# Editor for the doc comments in fmruby-core/sig/*.rbs -- the text the on-device
# editor shows as you type (Tab completion, Ctrl+T) and opens with F1.
#
# The point of a dedicated editor is that both halves of a doc comment have a
# limit that is not visible while writing one:
#
#   the summary   is copied into a fixed buffer and cut at 111 bytes without a
#                 word, and it carries both languages on one line
#   the long help is wrapped by a pane about 39 columns wide, which reads fine
#                 for prose and breaks a code example mid-token
#
# So the byte count is on screen while the summary is typed, and code lines too
# wide for the pane are listed. Signatures are never touched: this writes back
# the comment block and nothing else (tools/fm_sig_editor/test).
#
# Usage:
#   ruby tools/fm_sig_editor/fm_sig_editor.rb [SIG_DIR]
#
# Needs the glimmer-dsl-libui gem (gem install glimmer-dsl-libui) and the rbs
# gem, which the type database already needs. Under WSL2 the window comes up on
# WSLg.

require_relative "lib/fm_sig_editor"
require "shellwords"

sig_dir = ARGV[0] || FmSigEditor.default_sig_dir
sig_dir = File.expand_path(sig_dir)

unless Dir.exist?(sig_dir)
  warn "no sig directory at #{sig_dir}"
  warn "usage: ruby tools/fm_sig_editor/fm_sig_editor.rb [SIG_DIR]"
  exit 1
end

# WSL2 usually advertises a session bus that is not there, and GTK then
# complains on every settings write. Same treatment as fm_asset_editor.
if ENV["DBUS_SESSION_BUS_ADDRESS"].to_s.include?("unix:path=") && ENV["GSETTINGS_BACKEND"].nil?
  socket = ENV["DBUS_SESSION_BUS_ADDRESS"][/unix:path=([^,]+)/, 1]
  ENV["GSETTINGS_BACKEND"] = "memory" unless socket && File.exist?(socket)
end

require_relative "lib/fm_sig_editor/ui/main_window"

core_dir = File.expand_path("..", sig_dir)
FmSigEditor::Ui::MainWindow.new(sig_dir, core_dir).show

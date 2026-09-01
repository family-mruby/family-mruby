# frozen_string_literal: true

require_relative "fm_sig_editor/doc_comment"
require_relative "fm_sig_editor/sig_file"

module FmSigEditor
  # Where sig/ is, given this file's place in the tree.
  def self.default_sig_dir
    File.expand_path("../../../fmruby-core/sig", __dir__)
  end
end

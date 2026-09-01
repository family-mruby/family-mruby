# frozen_string_literal: true

require "rbs"
require_relative "doc_comment"

module FmSigEditor
  # One entry the editor can edit: a member of a class in sig/, its doc
  # comment, and where that comment sits in the file.
  Entry = Struct.new(:class_name, :name, :kind, :signature, :doc,
                     :comment_range, :member_line, :indent, keyword_init: true) do
    def label
      mark = doc.long? ? "*" : " "
      warn_mark = doc.summary_over? ? "!" : " "
      "#{mark}#{warn_mark} #{name}"
    end

    def title
      "#{class_name}##{name}"
    end
  end

  # A sig/*.rbs file, read through the RBS parser -- the same parser the help
  # generator and the type database use, so what this shows is attached to the
  # member the firmware attaches it to.
  #
  # Writing goes back through the lines, not through RBS: the parser does not
  # round-trip comments, and everything outside the comment being edited has to
  # come out byte for byte as it went in.
  class SigFile
    attr_reader :path, :entries

    def initialize(path)
      @path = path
      reload
    end

    def name
      File.basename(@path)
    end

    def reload
      @lines = File.readlines(@path)
      @entries = collect_entries
    end

    # Replace one comment block and write the file. Returns false when the
    # entry has no comment to replace (nothing in sig/ is undocumented today,
    # and inventing a place to put one is not this tool's job).
    def save(entry)
      return false if entry.comment_range.nil?

      body = entry.doc.to_text.split("\n", -1).map do |line|
        line.empty? ? "#{entry.indent}#\n" : "#{entry.indent}# #{line}\n"
      end
      first = entry.comment_range.first - 1
      last = entry.comment_range.last - 1
      @lines[first..last] = body
      File.write(@path, @lines.join)
      reload
      true
    end

    private

    def collect_entries
      buffer = RBS::Buffer.new(name: @path, content: @lines.join)
      _, _, decls = RBS::Parser.parse_signature(buffer)
      out = []
      each_class(decls) do |decl, class_name|
        decl.members.each do |member|
          entry = entry_for(member, class_name)
          out << entry if entry
        end
      end
      out
    end

    def each_class(decls, namespace = "", &block)
      decls.each do |decl|
        case decl
        when RBS::AST::Declarations::Class, RBS::AST::Declarations::Module
          full = "#{namespace}#{decl.name.relative!}".sub(/\A::/, "")
          block.call(decl, full)
          each_class(decl.members.grep(RBS::AST::Declarations::Base), "#{full}::", &block)
        end
      end
    end

    def entry_for(member, class_name)
      kind =
        case member
        when RBS::AST::Members::MethodDefinition then :method
        when RBS::AST::Declarations::Constant then :constant
        when RBS::AST::Members::InstanceVariable then :ivar
        end
      return nil unless kind
      return nil unless member.comment

      name = member.name.to_s
      loc = member.comment.location
      Entry.new(
        class_name: class_name,
        name: name,
        kind: kind,
        signature: signature_of(member, name),
        doc: DocComment.parse(strip_hashes(loc.start_line, loc.end_line)),
        comment_range: (loc.start_line..loc.end_line),
        member_line: member.location.start_line,
        indent: @lines[loc.start_line - 1][/\A\s*/]
      )
    end

    def signature_of(member, name)
      case member
      when RBS::AST::Members::MethodDefinition
        prefix = member.singleton? ? "self." : ""
        "#{prefix}#{name}#{member.overloads.first&.method_type}"
      when RBS::AST::Declarations::Constant
        "#{name}: #{member.type}"
      else
        "#{name}: #{member.type}"
      end
    end

    # The comment text without its "#" and the single space after it.
    def strip_hashes(start_line, end_line)
      @lines[(start_line - 1)..(end_line - 1)].map do |line|
        line.sub(/\A\s*#[ ]?/, "").chomp
      end.join("\n")
    end
  end
end

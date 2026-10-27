# frozen_string_literal: true

module Mls
  # Combines ripgrep (coarse, fast) with Ruby regexes (precise) and the Outline
  # (scope resolution) to answer: where is X defined, who calls X, what does X call.
  class Search
    Definition = Struct.new(:name, :kind, :file, :line, :text, :owner, :display, :start_line, :end_line,
                            keyword_init: true) do
      def method?
        kind != :class_def
      end
    end

    CallSite = Struct.new(:file, :line, :text, :kind, :col, :enclosing, :enclosing_line, :enclosing_end,
                          :match, :owner, :owner_line, :owner_end, keyword_init: true)

    DEF_KIND_ORDER = %i[def def_self define_method attr association scope delegate alias class_def].freeze

    def initialize(config)
      @config = config
    end

    attr_reader :config

    def outline(rel_file)
      Outline.for(config.absolute(rel_file))
    end

    # ---- definitions -----------------------------------------------------

    def find_definitions(name)
      return find_class_refs(name)[:definitions] if constant_name?(name)

      hits = Finder.search(coarse_pattern(name), config)
      defs = []
      hits.each do |hit|
        code = strip_comment(hit.text)
        kind = classify_definition(code, name)
        next unless kind
        ol = outline(hit.file)
        display, start_line, end_line = definition_display(ol, hit.line, name, kind)
        defs << Definition.new(
          name: name, kind: kind, file: hit.file, line: hit.line, text: hit.text.strip,
          owner: owner_at(ol, hit.line), display: display,
          start_line: start_line, end_line: end_line
        )
      end
      defs.sort_by { |d| [DEF_KIND_ORDER.index(d.kind) || 99, d.file, d.line] }
    end

    # ---- callers -------------------------------------------------------

    def find_callers(name)
      return find_class_refs(name)[:refs] if constant_name?(name)

      hits = Finder.search(coarse_pattern(name), config)
      sites = []
      hits.each do |hit|
        code = strip_comment(hit.text)
        next if definition_line?(code, name)
        kind, col, matched = classify_call(code, name)
        next unless kind
        sites << build_site(hit, kind, col, matched)
      end
      sites
    end

    # ---- class references ------------------------------------------------

    # Returns { definitions: [Definition], refs: [CallSite] }
    def find_class_refs(const)
      last = const.split("::").last
      hits = Finder.search("\\b#{Regexp.escape(last)}\\b", config)
      defs = []
      refs = []
      def_re = /^\s*(class|module)\s+((?:\w+::)*)#{Regexp.escape(last)}\b/
      ref_re = /(?<![\w@$])((?:::)?(?:[A-Z]\w*::)*)#{Regexp.escape(last)}\b(?!\s*=[^=~>])/
      hits.each do |hit|
        code = strip_comment(hit.text)
        if (m = def_re.match(code))
          ol = outline(hit.file)
          scope = ol.container_at(hit.line)
          display = scope ? ol.qualified_owner(scope) : "#{m[2]}#{last}"
          defs << Definition.new(
            name: const, kind: :class_def, file: hit.file, line: hit.line, text: hit.text.strip,
            owner: display, display: display,
            start_line: hit.line, end_line: scope ? scope.end_line : hit.line
          )
        elsif (m = ref_re.match(code))
          refs << build_site(hit, :const_ref, m.begin(0), m[0])
        end
      end
      # prefer refs that mention the full path, when a namespace was given
      if const.include?("::")
        refs.sort_by! { |r| [r.match.include?(const) ? 0 : 1, r.file, r.line] }
      end
      { definitions: defs, refs: refs }
    end

    # ---- callees -------------------------------------------------------

    def find_callees(file, start_line, end_line)
      outline(file).callees(start_line, end_line)
    end

    # ---- helpers -------------------------------------------------------

    def constant_name?(name)
      name =~ /\A(::)?[A-Z]/ ? true : false
    end

    # Coarse pattern for rg (Rust regex: no lookaround). Precise filtering happens in Ruby.
    def coarse_pattern(name)
      base = name.sub(/=\z/, "")
      "(^|[^A-Za-z0-9_])#{Regexp.escape(base)}([^A-Za-z0-9_]|$)"
    end

    # End-of-name assertion: next char is not an identifier char, not ?/! (so `foo` != `foo?`),
    # and not a single `=` (so `foo` != `foo=`; `foo==x`, `foo=>x`, `foo=~x` still match).
    def name_end
      '(?![\w?!])(?!=[^=~>])'
    end

    # Ruby-escaped name plus end assertion. Setter names (`foo=`) handled explicitly.
    def precise_name(name)
      if name.end_with?("=") && name.length > 1 && name !~ /\A[=<>!]/
        "#{Regexp.escape(name[0..-2])}\\s*=(?![=~>])"
      else
        "#{Regexp.escape(name)}#{name_end}"
      end
    end

    def no_assign
      '(?!\s*=[^=~>])'
    end

    def classify_definition(code, name)
      n = Regexp.escape(name.sub(/=\z/, ""))
      pn = precise_name(name)
      setter = name.end_with?("=") && name.length > 1
      e = name_end
      return :def_self if code =~ /^\s*def\s+self\.#{pn}/
      return :def if code =~ /^\s*def\s+#{pn}/
      return :define_method if code =~ /\bdefine_method\s*\(?\s*(?::#{pn}|["']#{n}["'])/
      if setter
        return :attr if code =~ /\battr_(?:writer|accessor)\b[^#]*:#{n}#{e}/
      else
        return :attr if code =~ /\b(?:attr_(?:reader|accessor)|[cm]attr_(?:reader|accessor)|thread_mattr_(?:reader|accessor)|class_attribute|attribute|store_accessor)\b[^#]*:#{n}#{e}/
        return :association if code =~ /\b(?:has_many|has_one|belongs_to|has_and_belongs_to_many)\s*\(?\s*:#{n}#{e}/
        return :scope if code =~ /\bscope\s*\(?\s*:#{n}#{e}/
        return :delegate if code =~ /\bdelegate\b[^#]*:#{n}#{e}/
      end
      return :alias if code =~ /\balias(?:_method)?\s*\(?\s*:?#{pn}/
      nil
    end

    def definition_line?(code, name)
      code =~ /^\s*def\s+(self\.)?#{precise_name(name)}/ ? true : false
    end

    # Returns [kind, col, matched_text] for the highest-priority call-shaped match, or nil.
    def classify_call(code, name)
      pn = precise_name(name)
      n = Regexp.escape(name.sub(/=\z/, ""))
      setter = name.end_with?("=") && name.length > 1
      patterns = if setter
        [
          [:dot_call, /(?:\.|&\.)#{pn}/],
          [:send, /\b(?:send|public_send|__send__|try!?)\s*\(?\s*:#{n}=/],
          [:symbol, /(?<![\w:]):#{n}=/],
          [:bare_call, /(?<![\w:.@$"'])self\.#{pn}/]
        ]
      else
        [
          [:dot_call, /(?:\.|&\.)#{pn}#{no_assign}/],
          [:block_symbol, /&:#{pn}/],
          [:send, /\b(?:send|public_send|__send__|try!?|respond_to\?|method|instance_method|define_method|alias_method)\s*\(?\s*(?::#{pn}|["']#{n}["'])/],
          [:bare_call, /(?<![\w:.@$"'])#{pn}#{no_assign}(?!:(?!:))/],
          [:symbol, /(?<![\w:]):#{pn}/],
          [:string, /["']#{n}["']/]
        ]
      end
      patterns.each do |kind, re|
        m = re.match(code)
        return [kind, m.begin(0), m[0]] if m
      end
      nil
    end

    # Removes a trailing `# comment` from a line of Ruby, respecting simple quotes.
    # Returns "" when the whole line is a comment.
    def strip_comment(text)
      return "" if text =~ /\A\s*#/
      quote = nil
      i = 0
      while i < text.length
        ch = text[i]
        if quote
          if ch == "\\"
            i += 1
          elsif ch == quote
            quote = nil
          end
        elsif ch == '"' || ch == "'" || ch == "`"
          quote = ch
        elsif ch == "#"
          return text[0...i]
        end
        i += 1
      end
      text
    end

    private

    def owner_at(ol, line)
      c = ol.enclosing_class(line)
      c ? ol.qualified_owner(c) : nil
    end

    def definition_display(ol, line, name, kind)
      case kind
      when :def, :def_self
        scope = ol.def_at(line)
        if scope
          [ol.display_name(scope), scope.start_line, scope.end_line]
        else
          [ol.macro_display_name(line, name, singleton: kind == :def_self), line, line]
        end
      when :scope
        [ol.macro_display_name(line, name, singleton: true), line, line]
      else
        [ol.macro_display_name(line, name), line, line]
      end
    end

    def build_site(hit, kind, col, matched)
      ol = outline(hit.file)
      d = ol.enclosing_def(hit.line)
      c = d ? nil : ol.enclosing_class(hit.line)
      CallSite.new(
        file: hit.file, line: hit.line, text: hit.text.strip, kind: kind, col: col, match: matched,
        enclosing: d ? ol.display_name(d) : nil,
        enclosing_line: d ? d.start_line : nil,
        enclosing_end: d ? d.end_line : nil,
        owner: c ? ol.qualified_owner(c) : nil,
        owner_line: c ? c.start_line : nil,
        owner_end: c ? c.end_line : nil
      )
    end
  end
end

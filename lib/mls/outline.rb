# frozen_string_literal: true

require "ripper"

module Mls
  # A per-file outline of class/module/def scopes with line ranges, built from
  # Ripper's sexp. Also extracts method calls (callees) within a line range.
  class Outline
    Scope = Struct.new(:kind, :name, :start_line, :end_line, :parent, :depth, keyword_init: true) do
      def contains?(line)
        line >= start_line && line <= end_line
      end

      def def?
        kind == :def || kind == :defs
      end

      def container?
        kind == :class || kind == :module
      end
    end

    Callee = Struct.new(:name, :receiver, :line, :count, :kind, keyword_init: true) do
      def label
        case kind
        when :class then name
        when :symbol_ref then ":#{name}"
        else receiver ? "#{receiver}.#{name}" : name
        end
      end
    end

    RUBY_BASENAMES = %w[Gemfile Rakefile config.ru Guardfile Capfile].freeze
    RUBY_EXTENSIONS = %w[.rb .rake .jbuilder .builder .gemspec .ru].freeze

    # Rails macros whose symbol arguments name methods.
    SYMBOL_ARG_MACROS = %w[
      before_action after_action around_action skip_before_action prepend_before_action
      before_validation after_validation before_save after_save before_create after_create
      before_update after_update before_destroy after_destroy after_commit after_rollback
      after_initialize after_find validate validates_with delegate alias_method
      helper_method rescue_from with_options
    ].freeze

    class << self
      def cache
        @cache ||= {}
      end

      def clear_cache
        @cache = {}
      end

      # Outline for an absolute path, cached by mtime.
      def for(path)
        mtime = File.mtime(path) rescue nil
        entry = cache[path]
        return entry[1] if entry && entry[0] == mtime

        source = File.read(path, encoding: "UTF-8") rescue ""
        source = source.scrub
        outline = parse(source, path: path)
        cache[path] = [mtime, outline]
        outline
      end

      def ruby_file?(path)
        base = File.basename(path)
        RUBY_BASENAMES.include?(base) || RUBY_EXTENSIONS.include?(File.extname(base))
      end

      def parse(source, path: nil)
        new(source, path: path)
      end
    end

    attr_reader :scopes, :path, :parsed

    def initialize(source, path: nil)
      @path = path
      @source = source
      @scopes = []
      @sexp = nil
      @parsed = false
      ruby = path.nil? || self.class.ruby_file?(path)
      if ruby
        @sexp = Ripper.sexp(source) rescue nil
      end
      if @sexp
        @parsed = true
        walk_scopes(@sexp, nil, 0)
      elsif ruby
        regex_outline
      end
      @scopes.sort_by! { |s| [s.start_line, s.depth] }
    end

    # Innermost def (or defs) containing the line, or nil.
    def enclosing_def(line)
      innermost(line) { |s| s.def? }
    end

    # Innermost class/module containing the line, or nil.
    def enclosing_class(line)
      innermost(line) { |s| s.container? }
    end

    # The def scope that starts on this line, if any.
    def def_at(line)
      @scopes.find { |s| s.def? && s.start_line == line }
    end

    # The class/module scope that starts on this line, if any.
    def container_at(line)
      @scopes.find { |s| s.container? && s.start_line == line }
    end

    # "A::B::C" for the chain of class/module ancestors (including scope itself if it is a container).
    def qualified_owner(scope)
      parts = []
      s = scope
      while s
        parts.unshift(s.name) if s.container?
        s = s.parent
      end
      parts.empty? ? nil : parts.join("::")
    end

    # Is this scope (a def) a singleton method? True for `def self.x` or a def inside `class << self`.
    def singleton?(scope)
      return true if scope.kind == :defs
      s = scope.parent
      while s && !s.container?
        return true if s.kind == :sclass
        s = s.parent
      end
      false
    end

    # "Owner#meth" / "Owner.meth" for a def scope; "Owner" for a container.
    def display_name(scope)
      return qualified_owner(scope) if scope.container?
      owner = qualified_owner(scope.parent)
      sep = singleton?(scope) ? "." : "#"
      owner ? "#{owner}#{sep}#{scope.name}" : "#{sep}#{scope.name}"
    end

    # Display name for an arbitrary line that is not itself a def: the enclosing def's
    # display name, or nil when the line is outside any def.
    def display_name_at(line)
      d = enclosing_def(line)
      d ? display_name(d) : nil
    end

    # Name for a macro-defined method (attr_reader, scope, has_many ...) on `line`.
    def macro_display_name(line, name, singleton: false)
      c = enclosing_class(line)
      owner = c ? qualified_owner(c) : nil
      sing = singleton || inside_sclass?(line)
      sep = sing ? "." : "#"
      owner ? "#{owner}#{sep}#{name}" : "#{sep}#{name}"
    end

    def inside_sclass?(line)
      s = innermost(line) { |x| x.kind == :sclass || x.container? }
      s && s.kind == :sclass
    end

    # Method calls and constant references between start_line and end_line (inclusive).
    # Returns Array of Callee sorted by first line.
    def callees(start_line, end_line)
      return [] unless @sexp

      found = {}
      collect_callees(@sexp, start_line, end_line) do |name, receiver, line, kind|
        key = [kind, name, receiver]
        if (c = found[key])
          c.count += 1
        else
          found[key] = Callee.new(name: name, receiver: receiver, line: line, count: 1, kind: kind)
        end
      end
      found.values.sort_by { |c| [c.line, c.name] }
    end

    def lines
      @lines ||= @source.lines.map(&:chomp)
    end

    private

    def innermost(line)
      best = nil
      @scopes.each do |s|
        next unless s.contains?(line) && yield(s)
        best = s if best.nil? || s.depth > best.depth
      end
      best
    end

    # ---- Ripper walking -------------------------------------------------

    def token?(node)
      node.is_a?(Array) && node[0].is_a?(Symbol) && node[0].to_s.start_with?("@") &&
        node[2].is_a?(Array) && node[2][0].is_a?(Integer)
    end

    # Walks the sexp, registering scopes. Returns the max token line in the subtree.
    def walk_scopes(node, parent, depth)
      return 0 unless node.is_a?(Array)
      return node[2][0] if token?(node)

      scope = nil
      case node[0]
      when :class, :module
        name = const_path_to_s(node[1])
        line = first_token_line(node[1])
        scope = Scope.new(kind: node[0], name: name, start_line: line, parent: parent, depth: depth)
      when :sclass
        line = first_token_line(node[1])
        scope = Scope.new(kind: :sclass, name: "self", start_line: line, parent: parent, depth: depth)
      when :def
        name_tok = node[1]
        scope = Scope.new(kind: :def, name: name_tok[1], start_line: name_tok[2][0], parent: parent, depth: depth)
      when :defs
        name_tok = node[3]
        scope = Scope.new(kind: :defs, name: name_tok[1], start_line: name_tok[2][0], parent: parent, depth: depth)
      end

      if scope
        @scopes << scope
        max = scope.start_line
        node.each { |c| max = [max, walk_scopes(c, scope, depth + 1)].max }
        scope.end_line = max
        max
      else
        max = 0
        node.each { |c| max = [max, walk_scopes(c, parent, depth)].max }
        max
      end
    end

    def first_token_line(node)
      return node[2][0] if token?(node)
      return 0 unless node.is_a?(Array)
      node.each do |c|
        l = first_token_line(c)
        return l if l > 0
      end
      0
    end

    def const_path_to_s(node)
      return "?" unless node.is_a?(Array)
      case node[0]
      when :const_ref, :top_const_ref, :top_const_field
        const_path_to_s(node[1])
      when :const_path_ref, :const_path_field
        "#{const_path_to_s(node[1])}::#{const_path_to_s(node[2])}"
      when :var_ref, :var_field
        const_path_to_s(node[1])
      when :@const
        node[1]
      else
        "?"
      end
    end

    # ---- callee extraction -------------------------------------------------

    def collect_callees(node, from, to, &blk)
      return unless node.is_a?(Array)
      return if token?(node)

      case node[0]
      when :call
        meth = node[3]
        if meth.is_a?(Array) && token?(meth)
          line = meth[2][0]
          blk.call(meth[1], receiver_text(node[1]), line, :method) if line.between?(from, to)
        end
        collect_callees(node[1], from, to, &blk)
        return
      when :command_call
        meth = node[3]
        if token?(meth)
          line = meth[2][0]
          blk.call(meth[1], receiver_text(node[1]), line, :method) if line.between?(from, to)
        end
        collect_callees(node[1], from, to, &blk)
        collect_callees(node[4], from, to, &blk)
        return
      when :fcall, :vcall
        tok = node[1]
        if token?(tok)
          line = tok[2][0]
          blk.call(tok[1], nil, line, :method) if line.between?(from, to)
        end
        return
      when :command
        tok = node[1]
        if token?(tok)
          line = tok[2][0]
          if line.between?(from, to)
            blk.call(tok[1], nil, line, :method)
            if SYMBOL_ARG_MACROS.include?(tok[1])
              symbol_args(node[2]).each { |sym, l| blk.call(sym, nil, l, :symbol_ref) }
            end
          end
        end
        collect_callees(node[2], from, to, &blk)
        return
      when :const_path_ref, :top_const_ref
        line = first_token_line(node)
        blk.call(const_path_to_s(node), nil, line, :class) if line.between?(from, to)
        return
      when :var_ref
        tok = node[1]
        if token?(tok) && tok[0] == :@const
          line = tok[2][0]
          blk.call(tok[1], nil, line, :class) if line.between?(from, to)
        end
        return
      when :const_ref
        # class/module definition name; not a reference
        return
      when :super
        line = first_token_line(node)
        blk.call("super", nil, line, :method) if line.between?(from, to)
      when :zsuper
        blk.call("super", nil, 0, :method) if false
      end

      node.each { |c| collect_callees(c, from, to, &blk) }
    end

    def symbol_args(args)
      out = []
      walk = lambda do |n|
        next unless n.is_a?(Array)
        if n[0] == :symbol_literal && n[1].is_a?(Array) && n[1][0] == :symbol && token?(n[1][1])
          out << [n[1][1][1], n[1][1][2][0]]
        elsif n[0] == :dyna_symbol
          # skip
        else
          n.each { |c| walk.call(c) }
        end
      end
      walk.call(args)
      out
    end

    def receiver_text(node, depth = 0)
      return nil if node.nil?
      return "…" if depth > 3 || !node.is_a?(Array)
      case node[0]
      when :var_ref, :var_field
        tok = node[1]
        token?(tok) ? tok[1] : "…"
      when :vcall, :fcall
        tok = node[1]
        token?(tok) ? tok[1] : "…"
      when :const_path_ref, :top_const_ref
        const_path_to_s(node)
      when :call
        meth = node[3]
        m = token?(meth) ? meth[1] : "…"
        "#{receiver_text(node[1], depth + 1)}.#{m}"
      when :method_add_arg
        receiver_text(node[1], depth + 1)
      when :method_add_block
        receiver_text(node[1], depth + 1)
      when :paren
        "(…)"
      when :string_literal
        "\"…\""
      when :array
        "[…]"
      when :hash
        "{…}"
      when :@ident, :@const, :@ivar, :@cvar, :@gvar, :@kw
        node[1]
      else
        "…"
      end
    end

    # ---- regex fallback for unparseable Ruby ----------------------------

    DEF_RE = /^(\s*)def\s+(self\.)?([A-Za-z_][\w]*[?!=]?|[<=>!~+\-*\/%^&|\[\]]+)/.freeze
    CONTAINER_RE = /^(\s*)(class|module)\s+([A-Z][\w:]*)/.freeze
    SCLASS_RE = /^(\s*)class\s*<<\s*self\b/.freeze

    def regex_outline
      stack = [] # [indent, scope]
      lines.each_with_index do |text, idx|
        lineno = idx + 1
        next if text.strip.empty?
        indent = text[/^\s*/].length

        # close scopes whose indent >= current indent, when we hit an `end` at that indent
        while (top = stack.last) && indent <= top[0] && text.strip.start_with?("end")
          top[1].end_line = lineno
          stack.pop
          break if indent == top[0]
        end

        parent = stack.last && stack.last[1]
        depth = stack.size
        if (m = SCLASS_RE.match(text))
          s = Scope.new(kind: :sclass, name: "self", start_line: lineno, parent: parent, depth: depth)
        elsif (m = CONTAINER_RE.match(text))
          s = Scope.new(kind: m[2].to_sym, name: m[3], start_line: lineno, parent: parent, depth: depth)
        elsif (m = DEF_RE.match(text))
          s = Scope.new(kind: m[2] ? :defs : :def, name: m[3], start_line: lineno, parent: parent, depth: depth)
          # one-line def with `; end`
          if text =~ /;\s*end\s*$/
            s.end_line = lineno
            @scopes << s
            next
          end
        else
          next
        end
        @scopes << s
        stack << [indent, s]
      end
      stack.each { |_, s| s.end_line ||= lines.size }
      @scopes.each { |s| s.end_line ||= lines.size }
    end
  end
end

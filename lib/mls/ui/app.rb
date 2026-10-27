# frozen_string_literal: true

require "mls/term"
require "mls/ui/modal"
require "mls/ui/prompt"
require "mls/ui/picker"
require "mls/ui/source_view"
require "mls/ui/help"
require "mls/ui/tree_view"

module Mls
  module UI
    class App
      NOISE = %w[
        new puts p pp print raise fail nil? present? blank? presence empty? any? none? each map select reject
        find detect first last count size length to_s to_i to_a to_h to_sym to_json inspect freeze dup tap then
        respond_to? is_a? kind_of? send public_send try try! fetch dig key? include? join split strip chomp
        merge merge! sort sort_by sum min max flatten compact uniq reverse push pop << class super
        private protected public attr_reader attr_writer attr_accessor require require_relative
        lambda proc loop times format sprintf
      ].freeze

      DETAIL_HEIGHT = 8

      def initialize(config, session:, search: nil, term: nil, initial_query: nil)
        @config = config
        @session = session
        @search = search || Search.new(config)
        @term = term || Term.new
        @cursor = 0
        @offset = 0
        @message = nil
        @initial_query = initial_query
        @dirty = false
      end

      def run
        @term.with do
          search_and_add_roots(@initial_query) if @initial_query
          loop do
            draw
            key = @term.read_key(timeout: 0.25)
            next if key.nil?
            @message = nil
            break if handle(key) == :quit
          end
        end
        save
      end

      # ---- rendering -----------------------------------------------------

      def visible
        TreeView.flatten(@session)
      end

      def current
        visible[@cursor]
      end

      def draw
        @term.draw(render(*@term.size))
      end

      def render(rows, cols)
        nodes = visible
        tree_height = rows - DETAIL_HEIGHT - 2
        @cursor, @offset = Modal.new(@term).clamp_scroll(@cursor, @offset, nodes.size, tree_height)
        lines = [header(cols)]
        if nodes.empty?
          lines << ""
          lines << Ansi.style("  No trees yet. Press / to search for a method or class, ? for help.", :dim)
        end
        nodes.each_with_index do |node, i|
          next if i < @offset || i >= @offset + tree_height
          row = TreeView.row(node, @session.hide_dismissed)
          row = Ansi.style(Ansi.fit(row, cols), :reverse) if i == @cursor
          lines << row
        end
        lines.fill("", lines.size, tree_height + 1 - lines.size) if lines.size < tree_height + 1
        lines.concat(detail(nodes[@cursor], cols))
        lines << status_bar(cols)
        lines
      end

      def header(cols)
        left = "#{Ansi.style('mls', :bold)} #{Ansi.style(@config.root, :dim)}"
        right = +"session: #{@config.relative(@session.path)}"
        right << "   hide dismissed: #{@session.hide_dismissed ? 'on' : 'off'}"
        right << "   excl: #{@config.all_excludes.size}#{@session.default_excludes ? '' : ' (no defaults)'}"
        right << "   backend: #{Finder.backend}"
        right << (@dirty ? "   *" : "")
        room = cols - Ansi.width(right) - 1
        left = Ansi.fit(left, room).rstrip if Ansi.width(left) > room && room > 8
        gap = cols - Ansi.width(left) - Ansi.width(right)
        gap = 1 if gap < 1
        Ansi.style(left + (" " * gap) + right, :underline)
      end

      def detail(node, cols)
        sep = Ansi.style("─" * cols, :dim)
        return [sep] + Array.new(DETAIL_HEIGHT - 1, "") unless node
        lines = [sep]
        head = +Ansi.style(node.name, :bold)
        head << "   #{node.file}:#{node.line}" if node.file && node.kind != :site
        head << "-#{node.end_line}" if node.end_line && node.end_line != node.line && node.kind != :site
        head << "   #{Ansi.style("[#{node.def_kind}]", :dim)}" if node.def_kind
        head << "   #{Ansi.style(node.status.to_s, node.confirmed? ? :green : :red)}" unless node.status == :unmarked
        head << "   #{Ansi.style('(unresolved: press i to find implementations)', :yellow)}" if node.unresolved?
        lines << head
        lines << "#{Ansi.style('note:', :yellow)} #{node.note}" if node.note && !node.note.empty?
        if node.parent && !node.sites.empty?
          rel = node.direction == :up ? "calls #{node.parent.name} at:" : "called from #{node.parent.name} at:"
          lines << Ansi.style(rel, :dim)
          node.sites.first(DETAIL_HEIGHT - lines.size - 1).each do |s|
            lines << "  #{Ansi.style("#{s['file']}:#{s['line']}", :cyan)} #{Ansi.style("[#{s['kind']}]", :dim)} #{s['text']}"
          end
          extra = node.sites.size - (DETAIL_HEIGHT - 4)
          lines[-1] = Ansi.style("  … #{extra} more site(s); press v to browse", :dim) if lines.size >= DETAIL_HEIGHT && extra.positive?
        elsif node.file && node.line
          src = source_line(node.file, node.line)
          lines << "  #{Ansi.style(src.strip, :dim)}" if src
          kids = node.children.size
          lines << Ansi.style("  #{kids} child node#{'s' if kids != 1}", :dim) if kids.positive?
        end
        lines = lines[0, DETAIL_HEIGHT]
        lines.fill("", lines.size, DETAIL_HEIGHT - lines.size) if lines.size < DETAIL_HEIGHT
        lines
      end

      def status_bar(cols)
        text = @message || "u callers  U auto-up  d callees  i impls  / search  y/n mark  m note  x delete  v view  o edit  e export  F filters  ? help  q quit"
        Ansi.style(Ansi.fit(text, cols), :reverse)
      end

      def source_line(file, line)
        @search.outline(file).lines[line - 1]
      rescue StandardError
        nil
      end

      # ---- key handling --------------------------------------------------

      def handle(key)
        node = current
        case key
        when "q", :ctrl_c then return :quit
        when "j", :down then @cursor += 1
        when "k", :up then @cursor -= 1
        when :pgdn then @cursor += 10
        when :pgup then @cursor -= 10
        when "g", :home then @cursor = 0
        when "G", :end then @cursor = visible.size - 1
        when "J" then move_sibling(1)
        when "K" then move_sibling(-1)
        when "h", :left
          if node && node.expanded && !node.children.empty?
            node.expanded = false
          elsif node&.parent
            @cursor = visible.index(node.parent) || @cursor
          end
        when "l", :right then node.expanded = true if node
        when :enter then node.expanded = !node.expanded if node
        when "-" then collapse_all(node) if node
        when "+", "=" then expand_all(node) if node
        when "/" then action_search
        when "u" then action_callers(node) if node
        when "U" then action_auto_up(node) if node
        when "d" then action_callees(node) if node
        when "i" then action_implementations(node) if node
        when "y" then set_status(node, :confirmed)
        when "n" then set_status(node, :dismissed)
        when " " then set_status(node, :unmarked)
        when "m" then action_note(node) if node
        when "x" then action_delete(node) if node
        when "D"
          @session.hide_dismissed = !@session.hide_dismissed
          mark_dirty
        when "F" then action_filters
        when "T"
          @session.default_excludes = !@session.default_excludes
          @config.apply_session(@session)
          mark_dirty
          @message = @session.default_excludes ? "default excludes on (vendor, spec, test, tmp, log …)" :
            "default excludes off: searching everything except your own excludes"
        when "v" then action_view(node) if node
        when "o" then open_editor(node.file, node.line) if node&.file
        when "e" then action_export
        when "w"
          save
          @message = "saved #{@session.path}"
        when "?" then Help.new(@term).run
        end
        nil
      end

      def move_sibling(delta)
        node = current
        return unless node
        siblings = node.parent ? node.parent.children : @session.roots
        siblings = siblings.reject(&:dismissed?) if @session.hide_dismissed
        i = siblings.index(node)
        target = siblings[i + delta] if i
        @cursor = visible.index(target) if target && (i + delta) >= 0
      end

      def collapse_all(node)
        node.expanded = false
        node.each_descendant { |n| n.expanded = false }
      end

      def expand_all(node)
        node.expanded = true
        node.each_descendant { |n| n.expanded = true }
      end

      def set_status(node, status)
        return unless node
        node.status = status
        mark_dirty
      end

      def mark_dirty
        @dirty = true
        save
      end

      def save
        @session.save
        @dirty = false
      rescue StandardError => e
        @message = "save failed: #{e.message}"
      end

      # ---- actions -------------------------------------------------------

      def prompt(label, default: "")
        Prompt.new(@term, label, default: default, background: render(*@term.size)).run
      end

      def confirm(question)
        @message = "#{question} (y/N)"
        draw
        key = @term.read_key
        @message = nil
        key == "y" || key == "Y"
      end

      def action_search
        q = prompt("Search method or Class:")
        return if q.nil? || q.strip.empty?
        search_and_add_roots(q.strip)
      end

      def search_and_add_roots(name)
        defs = with_status("searching definitions of #{name}…") { @search.find_definitions(name) }
        if defs.empty?
          if confirm("No definitions of '#{name}' found. Add it as an unresolved root anyway?")
            kind = @search.constant_name?(name) ? :class : :method
            node = Mls::Node.unresolved(name, kind: kind)
            @session.add_root(node)
            @cursor = visible.index(node) || @cursor
            mark_dirty
          end
          return
        end
        chosen = pick_definitions("Definitions of #{name}", defs, default_checked: true)
        return if chosen.nil? || chosen.empty?
        last = nil
        chosen.each do |d|
          n = Mls::Node.from_definition(d)
          existing = @session.roots.find { |r| r.identity == n.identity }
          if existing
            last = existing
          else
            @session.add_root(n)
            last = n
          end
        end
        @cursor = visible.index(last) || @cursor
        mark_dirty
        @message = "added #{chosen.size} root(s)"
      end

      def pick_definitions(title, defs, default_checked:, single: false)
        items = defs.map do |d|
          label = "#{Ansi.style("[#{d.kind}]".ljust(15), :dim)} #{Ansi.style(d.display, :bold)}  #{Ansi.style("#{d.file}:#{d.line}", :dim)}  #{d.text}"
          { label: label, checked: default_checked, value: d, location: [d.file, d.line, d.display] }
        end
        Picker.new(@term, title, items, source_viewer: method(:peek), single: single).run
      end

      def action_callers(node)
        name = node.search_name
        if name.nil?
          @message = "bare call sites have no method name; use v/o to inspect the file"
          return
        end
        sites = with_status("searching callers of #{name}…") { @search.find_callers(name) }
        if sites.empty?
          @message = "no callers of #{name} found"
          return
        end
        existing = node.children.map(&:identity)
        items = sites.map do |s|
          group = Mls::Node.from_sites([s], direction: :up)
          in_tree = existing.include?(group.identity)
          enclosing = s.enclosing || Ansi.style(s.owner ? "#{s.owner} (class body)" : "(no enclosing method)", :cyan)
          label = "#{Ansi.style("[#{s.kind}]".ljust(14), :dim)} #{Ansi.style(enclosing, :bold)}  #{Ansi.style("#{s.file}:#{s.line}", :dim)}  #{s.text}"
          noise = s.kind == :string
          { label: label, checked: !in_tree && !noise, value: s, location: [s.file, s.line, s.enclosing],
            tag: in_tree ? "(in tree)" : nil, noise: noise }
        end
        title = node.kind == :class ? "References to #{name}" : "Callers of #{name}"
        chosen = Picker.new(@term, title, items, source_viewer: method(:peek)).run
        return if chosen.nil? || chosen.empty?
        added = attach_sites(node, chosen, :up)
        node.expanded = true
        mark_dirty
        @message = "added #{added} caller node(s)"
      end

      def action_auto_up(node)
        if node.search_name.nil?
          @message = "bare call sites have no method name to climb from"
          return
        end
        answer = prompt("Auto-expand callers up to depth (blank = unlimited):")
        return if answer.nil?
        answer = answer.strip
        max_depth = nil
        unless answer.empty?
          unless answer =~ /\A\d+\z/ && answer.to_i.positive?
            @message = "depth must be a positive number (or blank for unlimited)"
            return
          end
          max_depth = answer.to_i
        end
        progress = lambda do |depth:, added:, name:|
          @message = "auto-expanding… depth #{depth}, +#{added} nodes, callers of #{name}  (Esc stops)"
          draw
        end
        cancelled = -> { @term.read_key(timeout: 0) == :esc }
        expander = Mls::Expander.new(@search, @session, max_depth: max_depth, progress: progress, cancelled: cancelled)
        result = begin
          expander.expand_up(node)
        rescue Mls::Error => e
          @message = "error: #{e.message}"
          nil
        end
        node.expanded = true
        mark_dirty
        return unless result
        suffix = case result.stopped
                 when :cap then " (stopped at #{Mls::Expander::DEFAULT_MAX_NODES}-node cap)"
                 when :cancelled then " (cancelled)"
                 when :depth then " (depth limit)"
                 else ""
                 end
        @message = "auto-expanded: +#{result.added} node(s), depth #{result.max_depth_reached}#{suffix}"
      end

      # Groups sites by enclosing def and attaches/merges them as children. Returns count of new nodes.
      def attach_sites(node, sites, direction)
        added = 0
        Mls::Node.group_sites(sites).each do |group|
          child = Mls::Node.from_sites(group, direction: direction)
          if (dup = node.find_child(child.identity))
            dup.merge_sites(child.sites)
          else
            node.add_child(child)
            added += 1
          end
        end
        added
      end

      def action_callees(node)
        if node.unresolved? || node.file.nil?
          @message = "node has no known source range; resolve it first (i)"
          return
        end
        from = node.line || 1
        to = node.end_line || from
        callees = with_status("parsing #{node.file}…") { @search.find_callees(node.file, from, to) }
        if callees.empty?
          @message = "no calls found in #{node.file}:#{from}-#{to}" + (@search.outline(node.file).parsed ? "" : " (file did not parse)")
          return
        end
        items = callees.map do |c|
          text = source_line(node.file, c.line).to_s.strip
          kind_tag = c.kind == :class ? "[class]" : (c.kind == :symbol_ref ? "[symbol]" : "[call]")
          label = "#{Ansi.style(kind_tag.ljust(8), :dim)} #{Ansi.style(c.label, :bold)}#{c.count > 1 ? Ansi.style(" ×#{c.count}", :dim) : ''}  #{Ansi.style("line #{c.line}", :dim)}  #{text}"
          { label: label, checked: false, value: c, location: [node.file, c.line, c.label], noise: NOISE.include?(c.name) }
        end
        chosen = Picker.new(@term, "Calls inside #{node.name}", items, source_viewer: method(:peek)).run
        return if chosen.nil? || chosen.empty?
        added = 0
        chosen.each { |c| added += attach_callee(node, c) }
        node.expanded = true
        mark_dirty
        @message = "added #{added} callee node(s)"
      end

      def attach_callee(node, callee)
        site = { "file" => node.file, "line" => callee.line, "text" => source_line(node.file, callee.line).to_s.strip,
                 "kind" => callee.kind == :class ? "const_ref" : "call" }
        defs = with_status("searching definitions of #{callee.name}…") { @search.find_definitions(callee.name) }
        chosen = if defs.empty?
                   []
                 elsif defs.size == 1
                   defs
                 else
                   pick_definitions("Implementations of #{callee.label} (#{defs.size}) — Esc skips", defs, default_checked: true)
                 end
        return 0 if chosen.nil?
        if chosen.empty?
          placeholder = Mls::Node.unresolved(callee.label, sites: [site], kind: callee.kind == :class ? :class : :method)
          return 0 if node.children.any? { |c| c.unresolved? && c.name == placeholder.name }
          node.add_child(placeholder)
          return 1
        end
        added = 0
        chosen.each do |d|
          child = Mls::Node.from_definition(d, direction: :down)
          child.sites = [site]
          if (dup = node.find_child(child.identity))
            dup.merge_sites([site])
          else
            node.add_child(child)
            added += 1
          end
        end
        added
      end

      def action_implementations(node)
        name = node.search_name
        if name.nil?
          @message = "bare call sites have no method name"
          return
        end
        defs = with_status("searching definitions of #{name}…") { @search.find_definitions(name) }
        if defs.empty?
          @message = "no definitions of #{name} found"
          return
        end
        chosen = pick_definitions("Implementations of #{name}", defs, default_checked: node.unresolved?)
        return if chosen.nil? || chosen.empty?
        siblings = node.parent ? node.parent.children : @session.roots
        first = chosen.shift
        if node.unresolved?
          resolve_into(node, first)
        else
          add_sibling(node, siblings, first)
        end
        chosen.each { |d| add_sibling(node, siblings, d) }
        mark_dirty
        @message = "resolved #{name}"
      end

      def resolve_into(node, d)
        node.kind = d.kind == :class_def ? :class : :method
        node.name = d.display
        node.file = d.file
        node.line = d.line
        node.end_line = d.end_line
        node.def_kind = d.kind
        node.resolved = true
      end

      def add_sibling(node, siblings, d)
        child = Mls::Node.from_definition(d, direction: node.direction)
        child.sites = node.sites.dup
        return if siblings.any? { |s| s.identity == child.identity }
        if node.parent
          node.parent.add_child(child)
        else
          @session.add_root(child)
        end
      end

      def action_filters
        text = prompt("Excluded dirs/globs (space-separated; 'spec' means spec/**):", default: @session.excludes.join(" "))
        return if text.nil?
        @session.excludes = Config.normalize_globs(text.split(/[\s,]+/))
        @config.apply_session(@session)
        mark_dirty
        @message = "excluding #{@session.excludes.size} glob(s)#{@session.default_excludes ? ' + defaults' : ''}: #{@session.excludes.join(' ')}"
      end

      def action_note(node)
        text = prompt("Note:", default: node.note.to_s)
        return if text.nil?
        node.note = text.strip.empty? ? nil : text.strip
        mark_dirty
      end

      def action_delete(node)
        count = 1
        node.each_descendant { count += 1 }
        return unless confirm("Delete #{node.name} and #{count - 1} descendant(s)?")
        @session.remove(node)
        @cursor = [@cursor, visible.size - 1].min
        mark_dirty
        @message = "deleted"
      end

      def locations_for(node)
        locs = []
        locs << [node.file, node.line, "definition: #{node.name}"] if node.file && node.line
        node.sites.each { |s| locs << [s["file"], s["line"], "call site [#{s['kind']}]"] }
        locs
      end

      def action_view(node)
        locs = locations_for(node)
        if locs.empty?
          @message = "nothing to view for an unresolved node"
          return
        end
        result = SourceView.new(@term, @config, locs).run
        open_editor(result[1], result[2]) if result.is_a?(Array) && result[0] == :open
      end

      def peek(location)
        file, line, label = location
        result = SourceView.new(@term, @config, [[file, line, label]]).run
        open_editor(result[1], result[2]) if result.is_a?(Array) && result[0] == :open
      end

      def open_editor(file, line)
        editor = ENV["VISUAL"] || ENV["EDITOR"]
        if editor.nil? || editor.empty?
          @message = "set $EDITOR to open files"
          return
        end
        abs = @config.absolute(file)
        @term.suspend do
          args = editor.split(" ")
          args << "+#{line}" if line
          args << abs
          system(*args)
        end
      end

      def action_export
        default = @config.export_default_path
        path = prompt("Export to:", default: default)
        return if path.nil? || path.strip.empty?
        path = File.expand_path(path.strip, @config.root)
        text = Export.render(@session, include_dismissed: !@session.hide_dismissed)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, text)
        @message = "exported #{@session.roots.size} tree(s) to #{path}#{@session.hide_dismissed ? '' : ' (dismissed included; press D to hide them)'}"
      rescue StandardError => e
        @message = "export failed: #{e.message}"
      end

      def with_status(text)
        @message = text
        draw
        result = yield
        @message = nil
        result
      rescue Mls::Error => e
        @message = "error: #{e.message}"
        []
      end
    end
  end
end

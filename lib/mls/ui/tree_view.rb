# frozen_string_literal: true

module Mls
  module UI
    # Pure rendering helpers for the tree pane (kept free of terminal I/O so they can be tested).
    module TreeView
      module_function

      # Depth-first list of visible nodes, honouring `expanded` and hide_dismissed.
      def flatten(session)
        out = []
        session.roots.each { |r| collect(r, session.hide_dismissed, out) }
        out
      end

      def collect(node, hide_dismissed, out)
        return if hide_dismissed && node.dismissed?
        out << node
        return unless node.expanded
        node.children.each { |c| collect(c, hide_dismissed, out) }
      end

      def glyph(node, hide_dismissed)
        kids = hide_dismissed ? node.children.reject(&:dismissed?) : node.children
        return "·" if kids.empty?
        node.expanded ? "▾" : "▸"
      end

      def arrow(node)
        return "↺" if node.repeat
        case node.direction
        when :up then "↑"
        when :down then "↓"
        else "●"
        end
      end

      def status_mark(node)
        case node.status
        when :confirmed then Ansi.style("✓", :green)
        when :dismissed then Ansi.style("✗", :red)
        else " "
        end
      end

      def location(node)
        return "" unless node.file
        node.kind == :site ? "" : (node.line ? "#{node.file}:#{node.line}" : node.file)
      end

      # One styled row (without cursor highlighting).
      def row(node, hide_dismissed)
        pad = "  " * node.depth
        name = node.name
        name = if node.unresolved?
                 Ansi.style("? #{name}", :yellow)
               elsif node.dismissed?
                 Ansi.style(name, :dim, :strike)
               elsif node.kind == :class
                 Ansi.style(name, :magenta)
               elsif node.kind == :site
                 Ansi.style(name, :cyan)
               else
                 Ansi.style(name, :bold)
               end
        extras = []
        extras << Ansi.style(location(node), :dim) unless location(node).empty?
        extras << Ansi.style("[#{node.def_kind}]", :dim) if node.def_kind && !%i[def class_def].include?(node.def_kind)
        extras << Ansi.style("(#{node.sites.size} site#{'s' if node.sites.size != 1})", :dim) if node.sites.size > 1
        extras << Ansi.style("✎", :yellow) if node.note && !node.note.empty?
        extras << Ansi.style("(see above)", :dim) if node.repeat
        "#{pad}#{glyph(node, hide_dismissed)} #{arrow(node)} #{status_mark(node)} #{name}  #{extras.join('  ')}"
      end
    end
  end
end

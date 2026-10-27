# frozen_string_literal: true

module Mls
  # Renders a session's trees as nested, human-readable Markdown-ish text.
  module Export
    INDENT = "  "

    class << self
      def render(session, include_dismissed: false)
        out = +""
        session.roots.each_with_index do |root, i|
          next if root.dismissed? && !include_dismissed
          out << "\n" if i.positive?
          out << "# #{heading(root)}\n"
          out << note_lines(root, 0)
          out << render_children(root, 0, include_dismissed)
        end
        out
      end

      def render_node(node, include_dismissed: false)
        out = +"# #{heading(node)}\n"
        out << note_lines(node, 0)
        out << render_children(node, 0, include_dismissed)
        out
      end

      private

      def render_children(node, depth, include_dismissed)
        out = +""
        node.children.each do |child|
          next if child.dismissed? && !include_dismissed
          pad = INDENT * depth
          out << "#{pad}- #{arrow(child)} #{heading(child)}\n"
          child.sites.each do |s|
            out << "#{pad}#{INDENT}#{INDENT}#{s['file']}:#{s['line']}: #{s['text']}\n"
          end
          out << note_lines(child, depth + 2)
          out << render_children(child, depth + 1, include_dismissed)
        end
        out
      end

      def note_lines(node, depth)
        return "" unless node.note && !node.note.empty?
        pad = INDENT * depth
        node.note.lines.map { |l| "#{pad}note: #{l.chomp}\n" }.join
      end

      def arrow(node)
        case node.direction
        when :up then "↑ called by"
        when :down then "↓ calls"
        else "•"
        end
      end

      def heading(node)
        parts = [node.name]
        if node.unresolved?
          parts << "— (unresolved)"
        elsif node.file
          loc = node.line ? "#{node.file}:#{node.line}" : node.file
          parts << "— #{loc}" unless node.kind == :site
        end
        tags = []
        tags << node.def_kind.to_s if node.def_kind && node.kind == :method && node.def_kind != :def
        tags << "class" if node.kind == :class
        tags << "site" if node.kind == :site
        tags << node.status.to_s if node.status != :unmarked
        parts << "[#{tags.join(', ')}]" unless tags.empty?
        parts.join("  ")
      end
    end
  end
end

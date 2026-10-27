# frozen_string_literal: true

module Mls
  module UI
    # Base class for a full-screen interaction with its own loop.
    # Subclasses implement `render(rows, cols) -> [lines]` and `handle(key) -> :continue | [:done, value]`.
    class Modal
      def initialize(term)
        @term = term
      end

      def run
        loop do
          rows, cols = @term.size
          @term.draw(render(rows, cols))
          key = @term.read_key(timeout: 0.25)
          next if key.nil?
          result = handle(key)
          return result[1] if result.is_a?(Array) && result[0] == :done
        end
      end

      # Keeps `cursor` within [0, count-1] and scrolls `offset` so the cursor is visible in `height` rows.
      def clamp_scroll(cursor, offset, count, height)
        cursor = [[cursor, count - 1].min, 0].max
        offset = cursor if cursor < offset
        offset = cursor - height + 1 if cursor >= offset + height
        offset = [offset, 0].max
        [cursor, offset]
      end

      def bar(text, cols)
        Ansi.style(Ansi.fit(text, cols), :reverse)
      end
    end
  end
end

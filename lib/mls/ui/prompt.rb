# frozen_string_literal: true

module Mls
  module UI
    # Single-line text input drawn over a background frame. Returns the String, or nil on Esc.
    class Prompt < Modal
      def initialize(term, label, default: "", background: [])
        super(term)
        @label = label
        @value = default.to_s.dup
        @cursor = @value.length
        @background = background
      end

      def render(rows, cols)
        lines = @background.dup
        lines = lines[0, rows - 2] || []
        lines.fill("", lines.size, rows - 2 - lines.size) if lines.size < rows - 2
        before = @value[0...@cursor]
        at = @value[@cursor] || " "
        after = @value[(@cursor + 1)..-1] || ""
        input = "#{Ansi.style(@label, :bold)} #{before}#{Ansi.style(at, :reverse)}#{after}"
        lines << bar("Enter: accept   Esc: cancel   Ctrl-U: clear", cols)
        lines << input
        lines
      end

      def handle(key)
        case key
        when :enter then return [:done, @value]
        when :esc, :ctrl_c then return [:done, nil]
        when :backspace
          if @cursor.positive?
            @value.slice!(@cursor - 1)
            @cursor -= 1
          end
        when :delete then @value.slice!(@cursor) if @cursor < @value.length
        when :left then @cursor -= 1 if @cursor.positive?
        when :right then @cursor += 1 if @cursor < @value.length
        when :home, :ctrl_a then @cursor = 0
        when :end, :ctrl_e then @cursor = @value.length
        when :ctrl_u
          @value = +""
          @cursor = 0
        when :ctrl_w
          head = @value[0...@cursor].sub(/\S+\s*\z/, "")
          @value = head + @value[@cursor..-1]
          @cursor = head.length
        when String
          @value.insert(@cursor, key)
          @cursor += key.length
        end
        :continue
      end
    end
  end
end

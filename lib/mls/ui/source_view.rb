# frozen_string_literal: true

module Mls
  module UI
    # Read-only scrollable view of a file. `locations` is an Array of [file, line, label];
    # `]` and `[` jump between them.
    class SourceView < Modal
      def initialize(term, config, locations, index: 0)
        super(term)
        @config = config
        @locations = locations
        @index = index
        load_location
      end

      def load_location
        file, line, = @locations[@index]
        @file = file
        @target = line || 1
        abs = @config.absolute(file)
        @lines = File.exist?(abs) ? File.read(abs, encoding: "UTF-8").scrub.lines.map(&:chomp) : ["(file not found: #{file})"]
        @top = nil
      end

      def render(rows, cols)
        height = rows - 2
        @top ||= [@target - height / 2, 1].max
        @top = [[@top, @lines.size - height + 1].min, 1].max
        label = @locations[@index][2]
        title = "#{Ansi.style(@file, :bold)}:#{@target}"
        title += "   #{Ansi.style(label, :dim)}" if label
        title += Ansi.style("   [#{@index + 1}/#{@locations.size}]", :dim) if @locations.size > 1
        lines = [title]
        numw = @lines.size.to_s.length
        (0...height).each do |i|
          n = @top + i
          break if n > @lines.size
          text = @lines[n - 1].gsub("\t", "    ")
          row = "#{n.to_s.rjust(numw)} │ #{text}"
          row = Ansi.style(Ansi.fit(row, cols), :reverse) if n == @target
          lines << row
        end
        lines.fill("", lines.size, rows - 1 - lines.size) if lines.size < rows - 1
        lines << bar("j/k: scroll   PgUp/PgDn   g/G   ]/[: next/prev location   o: open in $EDITOR   q/Esc: back", cols)
        lines
      end

      def handle(key)
        rows, = @term.size
        height = rows - 2
        case key
        when "q", :esc, :ctrl_c, "v" then return [:done, nil]
        when "j", :down then @top += 1
        when "k", :up then @top -= 1
        when :pgdn, " " then @top += height
        when :pgup then @top -= height
        when "g", :home then @top = 1
        when "G", :end then @top = @lines.size
        when "]", "n"
          @index = (@index + 1) % @locations.size
          load_location
        when "[", "p"
          @index = (@index - 1) % @locations.size
          load_location
        when "o" then return [:done, [:open, @file, @target]]
        end
        :continue
      end
    end
  end
end

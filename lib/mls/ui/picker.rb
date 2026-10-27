# frozen_string_literal: true

module Mls
  module UI
    # Multi-select list. Items are Hashes: { label: String (may be styled), checked: bool, value: Object,
    # noise: bool, location: [file, line] or nil, disabled: bool, tag: String }.
    # Returns the Array of selected values, or nil on cancel.
    class Picker < Modal
      def initialize(term, title, items, source_viewer: nil, show_noise: false, single: false)
        super(term)
        @title = title
        @items = items
        @source_viewer = source_viewer
        @show_noise = show_noise
        @single = single
        @cursor = 0
        @offset = 0
        @filter = +""
        @filter_mode = false
      end

      def visible
        @items.select do |it|
          next false if it[:noise] && !@show_noise
          @filter.empty? || Ansi.strip(it[:label]).downcase.include?(@filter.downcase)
        end
      end

      def render(rows, cols)
        items = visible
        height = rows - 4
        @cursor, @offset = clamp_scroll(@cursor, @offset, items.size, height)
        selected = @items.count { |it| it[:checked] }
        noise = @items.count { |it| it[:noise] }
        header = "#{@title}   #{Ansi.style("#{selected} selected · #{items.size}/#{@items.size} shown", :dim)}"
        header += Ansi.style("  (#{noise} noisy hidden, '.' shows)", :dim) if noise.positive? && !@show_noise
        lines = [header]
        filter_line = if @filter_mode
                        "#{Ansi.style('filter:', :bold)} #{@filter}#{Ansi.style(' ', :reverse)}"
                      elsif @filter.empty?
                        Ansi.style("/ to filter", :dim)
                      else
                        "#{Ansi.style('filter:', :bold)} #{@filter}   #{Ansi.style('(/ edit, Ctrl-U clear)', :dim)}"
                      end
        lines << filter_line
        if items.empty?
          lines << Ansi.style("  (nothing to show)", :dim)
        end
        items.each_with_index do |it, i|
          next if i < @offset || i >= @offset + height
          box = if it[:disabled] then Ansi.style("[-]", :dim)
                elsif it[:checked] then Ansi.style("[x]", :green)
                else "[ ]"
                end
          tag = it[:tag] ? " #{Ansi.style(it[:tag], :dim)}" : ""
          row = "#{box} #{it[:label]}#{tag}"
          row = Ansi.style(Ansi.fit(row, cols), :reverse) if i == @cursor
          lines << row
        end
        lines.fill("", lines.size, rows - 1 - lines.size) if lines.size < rows - 1
        hints = @single ? "Enter: choose   Esc: cancel   / filter   v: view source" :
          "space: toggle   a: all   n: none   Enter: confirm   Esc: cancel   / filter   v: view source   .: noise"
        lines << bar(hints, cols)
        lines
      end

      def handle(key)
        items = visible
        if @filter_mode
          case key
          when :esc, :enter then @filter_mode = false
          when :backspace then @filter.slice!(-1)
          when :ctrl_u then @filter = +""
          when String then @filter << key
          end
          @cursor = 0
          return :continue
        end
        case key
        when :esc, :ctrl_c, "q" then return [:done, nil]
        when :enter
          if @single
            it = items[@cursor]
            return [:done, it ? [it[:value]] : nil]
          end
          return [:done, @items.select { |it| it[:checked] && !it[:disabled] }.map { |it| it[:value] }]
        when "j", :down then @cursor += 1
        when "k", :up then @cursor -= 1
        when :pgdn then @cursor += 20
        when :pgup then @cursor -= 20
        when "g", :home then @cursor = 0
        when "G", :end then @cursor = items.size - 1
        when " ", "x"
          it = items[@cursor]
          if it && !it[:disabled]
            it[:checked] = !it[:checked]
            @cursor += 1
          end
        when "a" then items.each { |it| it[:checked] = true unless it[:disabled] }
        when "n" then items.each { |it| it[:checked] = false }
        when "." then @show_noise = !@show_noise
        when "/" then @filter_mode = true
        when :ctrl_u then @filter = +""
        when "v"
          it = items[@cursor]
          @source_viewer&.call(it[:location]) if it && it[:location]
        end
        :continue
      end
    end
  end
end

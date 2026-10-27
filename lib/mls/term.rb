# frozen_string_literal: true

require "io/console"

module Mls
  # ANSI styling helpers and width-aware string fitting.
  module Ansi
    RESET = "\e[0m"
    STYLES = {
      bold: "\e[1m", dim: "\e[2m", italic: "\e[3m", underline: "\e[4m", reverse: "\e[7m", strike: "\e[9m",
      red: "\e[31m", green: "\e[32m", yellow: "\e[33m", blue: "\e[34m", magenta: "\e[35m", cyan: "\e[36m",
      white: "\e[37m", bright_black: "\e[90m", bg_blue: "\e[44m", bg_white: "\e[47m", bg_black: "\e[40m"
    }.freeze
    ESCAPE_RE = /\e\[[0-9;?]*[A-Za-z]/.freeze

    module_function

    def style(text, *styles)
      return text.to_s if styles.empty?
      "#{styles.map { |s| STYLES.fetch(s) }.join}#{text}#{RESET}"
    end

    def strip(text)
      text.gsub(ESCAPE_RE, "")
    end

    def width(text)
      strip(text).each_grapheme_cluster.count
    end

    # Truncates to `cols` visible cells (adding an ellipsis when cut) and pads with spaces.
    def fit(text, cols)
      return "" if cols <= 0
      out = +""
      visible = 0
      cut = false
      scanner = text.to_s
      i = 0
      while i < scanner.length
        if scanner[i] == "\e" && (m = scanner.match(ESCAPE_RE, i)) && m.begin(0) == i
          out << m[0]
          i += m[0].length
          next
        end
        ch = scanner[i]
        if visible >= cols - 1 && i < scanner.length - 1 && remaining_visible(scanner, i) > 1
          out << "…"
          visible += 1
          cut = true
          break
        end
        out << ch
        visible += 1
        i += 1
        break if visible >= cols
      end
      out << RESET if cut || out.include?("\e[")
      out << (" " * (cols - visible)) if visible < cols
      out
    end

    def remaining_visible(text, from)
      width(text[from..-1])
    end
  end

  # Raw-mode terminal: key reading, full-frame drawing, suspend/resume.
  class Term
    attr_reader :output

    KEYMAP = {
      "\e[A" => :up, "\e[B" => :down, "\e[C" => :right, "\e[D" => :left,
      "\eOA" => :up, "\eOB" => :down, "\eOC" => :right, "\eOD" => :left,
      "\e[5~" => :pgup, "\e[6~" => :pgdn, "\e[H" => :home, "\e[F" => :end,
      "\e[1~" => :home, "\e[4~" => :end, "\e[7~" => :home, "\e[8~" => :end, "\eOH" => :home, "\eOF" => :end,
      "\e[3~" => :delete, "\e[Z" => :shift_tab
    }.freeze

    def initialize(input: $stdin, output: $stdout)
      @input = input
      @output = output
      @active = false
      @resized = false
      @pending = +""
    end

    def tty?
      @input.respond_to?(:tty?) && @input.tty? && @output.respond_to?(:tty?) && @output.tty?
    end

    def start
      return if @active
      raise Mls::Error, "mls needs an interactive terminal (stdin/stdout are not a TTY)" unless tty?
      @input.raw!
      @output.write("\e[?1049h\e[?25l\e[H\e[2J")
      @output.flush
      @active = true
      @old_winch = trap("WINCH") { @resized = true }
    end

    def stop
      return unless @active
      @output.write("\e[0m\e[?25h\e[?1049l")
      @output.flush
      @input.cooked!
      trap("WINCH", @old_winch || "DEFAULT")
      @active = false
    end

    def with
      start
      yield self
    ensure
      stop
    end

    # Temporarily restores the normal terminal (e.g. to run $EDITOR).
    def suspend
      stop
      yield
    ensure
      start
      @resized = true
    end

    def resized?
      r = @resized
      @resized = false
      r
    end

    def size
      rows, cols = @output.winsize
      [rows, cols]
    rescue StandardError
      [24, 80]
    end

    # Reads one key. Returns a Symbol for special keys, a String for printable
    # characters, or nil on timeout.
    def read_key(timeout: nil)
      ch = read_char(timeout)
      return nil if ch.nil?
      case ch
      when "\e"
        seq = +"\e"
        while (c = read_char(0.03))
          seq << c
          break if seq.length >= 2 && c =~ /[A-Za-z~]/
          break if seq.length > 8
        end
        return :esc if seq == "\e"
        KEYMAP[seq] || :unknown
      when "\r", "\n" then :enter
      when "\x7f", "\b" then :backspace
      when "\t" then :tab
      when "\x03" then :ctrl_c
      when "\x04" then :ctrl_d
      when "\x1a" then :ctrl_z
      when "\x0c" then :ctrl_l
      when "\x15" then :ctrl_u
      when "\x17" then :ctrl_w
      when "\x01" then :ctrl_a
      when "\x05" then :ctrl_e
      else
        ch
      end
    end

    # Writes a full frame; `lines` are already-styled strings, one per row.
    def draw(lines)
      rows, cols = size
      buf = +"\e[H"
      rows.times do |i|
        buf << Ansi.fit(lines[i] || "", cols)
        buf << "\e[K"
        buf << "\r\n" if i < rows - 1
      end
      @output.write(buf)
      @output.flush
    end

    private

    def read_char(timeout)
      return @pending.slice!(0) unless @pending.empty?
      if timeout
        ready = IO.select([@input], nil, nil, timeout)
        return nil unless ready
      end
      first = @input.getc
      return nil if first.nil?
      first = first.b
      # assemble UTF-8 multibyte sequence
      need = utf8_len(first.ord) - 1
      bytes = first.dup
      need.times do
        b = @input.getc
        break if b.nil?
        bytes << b.b
      end
      bytes.force_encoding("UTF-8")
      bytes.valid_encoding? ? bytes : "?"
    rescue IOError, Errno::EIO
      nil
    end

    def utf8_len(byte)
      return 1 if byte < 0x80
      return 2 if byte & 0xE0 == 0xC0
      return 3 if byte & 0xF0 == 0xE0
      return 4 if byte & 0xF8 == 0xF0
      1
    end
  end
end

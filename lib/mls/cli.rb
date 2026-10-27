# frozen_string_literal: true

require "optparse"

module Mls
  module CLI
    module_function

    def run(argv, out: $stdout, err: $stderr)
      config = Config.new
      opts = { export: nil, include_dismissed: false, definitions: nil, callers: nil, callees: nil }
      parser = OptionParser.new do |o|
        o.banner = <<~TXT
          Usage: mls [options] [NAME]

          Interactive call-tree explorer for Ruby/Rails codebases. NAME (a method or Class)
          is searched immediately on start.
        TXT
        o.on("-r", "--root PATH", "Codebase root (default: current directory)") { |v| config.root = File.expand_path(v) }
        o.on("-s", "--session PATH", "Session file (default: ROOT/.mls/session.json)") { |v| opts[:session] = v }
        o.on("--include GLOB", "Add a file glob to search (repeatable)") { |v| config.includes << v }
        o.on("--exclude GLOB", "Add a glob to skip (repeatable)") { |v| config.excludes << v }
        o.on("--no-default-excludes", "Search vendor/, node_modules/, tmp/, log/ … too") { config.default_excludes = false }
        o.on("--no-rg", "Use the pure-Ruby searcher even if ripgrep is installed") { Finder.backend = :ruby }
        o.on("--export PATH", "Write the session's trees to PATH and exit") { |v| opts[:export] = v }
        o.on("--include-dismissed", "Include dismissed nodes in --export") { opts[:include_dismissed] = true }
        o.on("--definitions NAME", "Print definitions of NAME and exit") { |v| opts[:definitions] = v }
        o.on("--callers NAME", "Print call-shaped references to NAME and exit") { |v| opts[:callers] = v }
        o.on("--callees FILE:START[-END]", "Print calls inside a line range and exit") { |v| opts[:callees] = v }
        o.on("-v", "--version") { out.puts "mls #{VERSION}"; return 0 }
        o.on("-h", "--help") { out.puts o; return 0 }
      end
      rest = parser.parse(argv)
      config.session_path = File.expand_path(opts[:session], config.root) if opts[:session]
      unless File.directory?(config.root)
        err.puts "mls: root is not a directory: #{config.root}"
        return 2
      end

      search = Search.new(config)
      if opts[:definitions]
        search.find_definitions(opts[:definitions]).each do |d|
          out.puts "#{d.kind.to_s.ljust(14)} #{d.display.ljust(40)} #{d.file}:#{d.line}  #{d.text}"
        end
        return 0
      end
      if opts[:callers]
        search.find_callers(opts[:callers]).each do |c|
          out.puts "#{c.kind.to_s.ljust(14)} #{(c.enclosing || '-').ljust(40)} #{c.file}:#{c.line}  #{c.text}"
        end
        return 0
      end
      if opts[:callees]
        file, range = opts[:callees].split(":", 2)
        from, to = range.to_s.split("-").map(&:to_i)
        to ||= from
        search.find_callees(config.relative(file), from, to).each do |c|
          out.puts "#{c.kind.to_s.ljust(12)} #{c.label.ljust(40)} line #{c.line}#{c.count > 1 ? " ×#{c.count}" : ''}"
        end
        return 0
      end

      session = Session.load_or_new(config.session_path, root_path: config.root)
      if opts[:export]
        text = Export.render(session, include_dismissed: opts[:include_dismissed])
        if opts[:export] == "-"
          out.print text
        else
          File.write(opts[:export], text)
          err.puts "wrote #{opts[:export]}"
        end
        return 0
      end

      UI::App.new(config, session: session, search: search, initial_query: rest.first).run
      0
    rescue Mls::Error => e
      err.puts "mls: #{e.message}"
      1
    rescue Interrupt
      1
    end
  end
end

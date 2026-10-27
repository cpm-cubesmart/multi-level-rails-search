# frozen_string_literal: true

require "optparse"

module Mls
  module CLI
    module_function

    def run(argv, out: $stdout, err: $stderr)
      config = Config.new
      opts = { export: nil, include_dismissed: false, definitions: nil, callers: nil, callees: nil,
               excludes: [], default_excludes: nil, tree: nil, depth: nil }
      parser = OptionParser.new do |o|
        o.banner = <<~TXT
          Usage: mls [options] [NAME]

          Interactive call-tree explorer for Ruby/Rails codebases. NAME (a method or Class)
          is searched immediately on start.
        TXT
        o.on("-r", "--root PATH", "Codebase root (default: current directory)") { |v| config.root = File.expand_path(v) }
        o.on("-s", "--session PATH", "Session file (default: ROOT/.mls/session.json)") { |v| opts[:session] = v }
        o.on("--include GLOB", "Add a file glob to search (repeatable)") { |v| config.includes << v }
        o.on("--exclude GLOB", "Skip a dir or glob, remembered in the session (repeatable; 'spec' means spec/**)") { |v| opts[:excludes] << v }
        o.on("--[no-]default-excludes", "Also search vendor/, spec/, test/, tmp/, log/ … (remembered)") { |v| opts[:default_excludes] = v }
        o.on("--no-rg", "Use the pure-Ruby searcher even if ripgrep is installed") { Finder.backend = :ruby }
        o.on("--export PATH", "Write the session's trees to PATH and exit") { |v| opts[:export] = v }
        o.on("--include-dismissed", "Include dismissed nodes in --export") { opts[:include_dismissed] = true }
        o.on("--definitions NAME", "Print definitions of NAME and exit") { |v| opts[:definitions] = v }
        o.on("--callers NAME", "Print call-shaped references to NAME and exit") { |v| opts[:callers] = v }
        o.on("--callees FILE:START[-END]", "Print calls inside a line range and exit") { |v| opts[:callees] = v }
        o.on("--tree NAME", "Build the full callers-of-callers tree for NAME and print it (or --export FILE)") { |v| opts[:tree] = v }
        o.on("--depth N", Integer, "Max depth for --tree (default: unlimited, 500-node cap)") { |v| opts[:depth] = v }
        o.on("-v", "--version") { out.puts "mls #{VERSION}"; return 0 }
        o.on("-h", "--help") { out.puts o; return 0 }
      end
      rest = parser.parse(argv)
      config.session_path = File.expand_path(opts[:session], config.root) if opts[:session]
      unless File.directory?(config.root)
        err.puts "mls: root is not a directory: #{config.root}"
        return 2
      end

      session = Session.load_or_new(config.session_path, root_path: config.root)
      changed = session.add_excludes(opts[:excludes])
      unless opts[:default_excludes].nil? || opts[:default_excludes] == session.default_excludes
        session.default_excludes = opts[:default_excludes]
        changed = true
      end
      config.apply_session(session)
      session.save if changed

      search = Search.new(config)
      if opts[:depth] && !opts[:tree]
        err.puts "mls: --depth only applies with --tree"
        return 2
      end
      if opts[:tree]
        return run_tree(opts, config, search, out, err)
      end
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

    def run_tree(opts, config, search, out, err)
      name = opts[:tree]
      session = Session.new(root_path: config.root)
      defs = search.find_definitions(name)
      if defs.empty?
        session.add_root(Node.unresolved(name, kind: search.constant_name?(name) ? :class : :method))
      else
        defs.each { |d| session.add_root(Node.from_definition(d)) }
      end
      show_progress = err.respond_to?(:tty?) && err.tty?
      progress = show_progress ? ->(depth:, added:, name:) { err.print "\r\e[Kdepth #{depth}, +#{added} nodes, callers of #{name}" } : nil
      expander = Expander.new(search, session, max_depth: opts[:depth], progress: progress)
      results = session.roots.map { |r| expander.expand_up(r) }
      err.print "\r\e[K" if show_progress
      results.each_with_index do |r, i|
        next unless r.stopped == :cap
        err.puts "note: #{session.roots[i].name} stopped at the #{Expander::DEFAULT_MAX_NODES}-node cap"
      end
      text = Export.render(session, include_dismissed: true)
      if opts[:export] && opts[:export] != "-"
        File.write(opts[:export], text)
        err.puts "wrote #{opts[:export]}"
      else
        out.print text
      end
      0
    end
  end
end

# frozen_string_literal: true

require "find"

module Mls
  # Picks ripgrep when available, otherwise a pure-Ruby directory grep.
  # Patterns must be valid in both Rust-regex and Ruby syntax (no lookaround).
  module Finder
    class << self
      def backend
        @backend ||= (ENV["MLS_NO_RG"] ? :ruby : (Ripgrep.available? ? :rg : :ruby))
      end

      def backend=(value)
        @backend = value
      end

      def search(pattern, config)
        if backend == :rg
          Ripgrep.search(pattern, config)
        else
          RubyGrep.search(pattern, config)
        end
      end
    end
  end

  module RubyGrep
    MAX_FILE_BYTES = 2 * 1024 * 1024
    FILE_LIST_TTL = 5 # seconds

    class << self
      def search(pattern, config)
        re = Regexp.new(pattern)
        hits = []
        files(config).each do |rel|
          abs = config.absolute(rel)
          begin
            next if File.size(abs) > MAX_FILE_BYTES
            File.foreach(abs, encoding: "UTF-8").with_index(1) do |line, lineno|
              line = line.scrub
              m = re.match(line)
              next unless m
              hits << Ripgrep::Hit.new(file: rel, line: lineno, text: line.chomp, col: m.begin(0))
            end
          rescue SystemCallError, IOError
            next
          end
        end
        hits
      end

      def files(config)
        key = [config.root, config.includes, config.all_excludes]
        now = Time.now
        @cache ||= nil
        if @cache && @cache[0] == key && now - @cache[1] < FILE_LIST_TTL
          return @cache[2]
        end
        list = walk(config)
        @cache = [key, now, list]
        list
      end

      def clear_cache
        @cache = nil
      end

      def included?(rel, config)
        return false if config.all_excludes.any? { |g| glob_match?(g, rel) }
        config.includes.any? { |g| glob_match?(g, rel) }
      end

      # rg-like glob semantics: a glob without "/" matches the basename anywhere;
      # one with "/" is anchored at the root. "dir/**" matches everything under dir.
      def glob_match?(glob, rel)
        if glob.end_with?("/**")
          prefix = glob[0..-4]
          return rel == prefix || rel.start_with?(prefix + "/")
        end
        if glob.include?("/")
          File.fnmatch(glob, rel, File::FNM_PATHNAME | File::FNM_DOTMATCH | File::FNM_EXTGLOB)
        else
          File.fnmatch(glob, File.basename(rel), File::FNM_DOTMATCH | File::FNM_EXTGLOB)
        end
      end

      private

      def walk(config)
        root = config.root
        list = []
        dir_excludes = config.all_excludes.select { |g| g.end_with?("/**") }.map { |g| g[0..-4] }
        Find.find(root) do |path|
          next if path == root
          rel = path[(root.length + 1)..-1]
          if File.directory?(path)
            Find.prune if dir_excludes.include?(rel) || File.basename(path) == ".git"
            next
          end
          next unless File.file?(path)
          list << rel if included?(rel, config)
        end
        list.sort
      end
    end
  end
end

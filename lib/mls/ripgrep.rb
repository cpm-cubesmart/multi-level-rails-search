# frozen_string_literal: true

require "json"
require "open3"

module Mls
  # Thin wrapper around `rg --json`.
  module Ripgrep
    Hit = Struct.new(:file, :line, :text, :col, keyword_init: true)

    class << self
      def available?
        !!binary
      end

      def binary
        @binary ||= ENV["MLS_RG"] || find_in_path("rg")
      end

      # Returns an Array of Hit with file paths relative to config.root.
      def search(pattern, config, case_sensitive: true)
        raise Mls::Error, "ripgrep (rg) not found in PATH" unless available?

        args = [binary, "--no-config", "--json", "--line-number", "--no-messages"]
        args << "--case-sensitive" if case_sensitive
        config.includes.each { |g| args += ["-g", g] }
        config.all_excludes.each { |g| args += ["-g", "!#{g}"] }
        args += ["-e", pattern, "--", "."]

        out, err, status = Open3.capture3(*args, chdir: config.root)
        # rg exits 1 when there are no matches, 2 on error.
        if status.exitstatus == 2 && out.empty?
          raise Mls::Error, "rg failed: #{err.strip}"
        end

        parse(out, config)
      end

      def parse(out, config)
        hits = []
        out.each_line do |raw|
          obj = JSON.parse(raw) rescue next
          next unless obj["type"] == "match"
          data = obj["data"]
          path = data.dig("path", "text") or next
          text = data.dig("lines", "text") or next
          first = data["submatches"]&.first
          hits << Hit.new(
            file: config.relative(path),
            line: data["line_number"],
            text: text.chomp,
            col: first ? first["start"] : 0
          )
        end
        hits.sort_by! { |h| [h.file, h.line] }
        hits
      end

      private

      def find_in_path(name)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
          cand = File.join(dir, name)
          return cand if File.executable?(cand) && !File.directory?(cand)
        end
        nil
      end
    end
  end
end

# frozen_string_literal: true

module Mls
  class Config
    DEFAULT_INCLUDES = %w[
      *.rb *.rake *.erb *.haml *.slim *.jbuilder *.builder Gemfile Rakefile config.ru
    ].freeze

    DEFAULT_EXCLUDES = %w[
      vendor/** node_modules/** tmp/** log/** public/** coverage/**
      spec/** test/** features/**
      db/schema.rb db/structure.sql .git/** .mls/**
    ].freeze

    GLOB_CHARS = /[*?\[\]{}]/.freeze

    # "spec" / "spec/" / "./spec" -> "spec/**"; globs and file paths are left alone.
    def self.normalize_glob(str)
      g = str.to_s.strip.sub(%r{\A\./}, "").sub(%r{/+\z}, "")
      return nil if g.empty?
      return g if g =~ GLOB_CHARS
      return g if File.basename(g).include?(".")
      "#{g}/**"
    end

    def self.normalize_globs(list)
      list.map { |g| normalize_glob(g) }.compact.uniq
    end

    attr_accessor :root, :includes, :excludes, :default_excludes
    attr_writer :session_path

    def initialize(root: Dir.pwd)
      @root = File.expand_path(root)
      @includes = DEFAULT_INCLUDES.dup
      @excludes = []
      @default_excludes = true
      @session_path = nil
    end

    def all_excludes
      (default_excludes ? DEFAULT_EXCLUDES : []) + excludes
    end

    # Takes the persisted exclude settings from a Session.
    def apply_session(session)
      @excludes = session.excludes.dup
      @default_excludes = session.default_excludes
      RubyGrep.clear_cache
      self
    end

    def session_path
      @session_path || File.join(root, ".mls", "session.json")
    end

    def export_default_path
      File.join(root, ".mls", "export-#{Time.now.strftime('%Y%m%d-%H%M%S')}.md")
    end

    def relative(path)
      abs = File.expand_path(path, root)
      abs.start_with?(root + "/") ? abs[(root.length + 1)..-1] : abs
    end

    def absolute(path)
      File.expand_path(path, root)
    end
  end
end

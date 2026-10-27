# frozen_string_literal: true

module Mls
  class Config
    DEFAULT_INCLUDES = %w[
      *.rb *.rake *.erb *.haml *.slim *.jbuilder *.builder Gemfile Rakefile config.ru
    ].freeze

    DEFAULT_EXCLUDES = %w[
      vendor/** node_modules/** tmp/** log/** public/** coverage/**
      db/schema.rb db/structure.sql .git/** .mls/**
    ].freeze

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

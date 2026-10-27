# frozen_string_literal: true

require "json"
require "securerandom"
require "fileutils"
require "time"

module Mls
  # A node in an exploration tree: a method, a class, or a bare call site.
  class Node
    KINDS = %i[method class site].freeze
    STATUSES = %i[unmarked confirmed dismissed].freeze
    DIRECTIONS = %i[root up down].freeze

    attr_accessor :id, :kind, :name, :file, :line, :end_line, :def_kind, :direction,
                  :sites, :status, :note, :expanded, :children, :resolved, :parent

    def initialize(kind:, name:, file: nil, line: nil, end_line: nil, def_kind: nil, direction: :root,
                   sites: [], status: :unmarked, note: nil, expanded: true, children: [], resolved: true,
                   id: nil, parent: nil)
      @id = id || SecureRandom.hex(4)
      @kind = kind
      @name = name
      @file = file
      @line = line
      @end_line = end_line
      @def_kind = def_kind
      @direction = direction
      @sites = sites
      @status = status
      @note = note
      @expanded = expanded
      @children = children
      @resolved = resolved
      @parent = parent
      @children.each { |c| c.parent = self }
    end

    def self.from_definition(d, direction: :root)
      new(kind: d.kind == :class_def ? :class : :method, name: d.display, file: d.file, line: d.line,
          end_line: d.end_line, def_kind: d.kind, direction: direction)
    end

    # A caller node for one or more call sites that share an enclosing def.
    def self.from_sites(sites, direction: :up)
      first = sites.first
      site_hashes = sites.map { |s| site_to_h(s) }
      if first.enclosing
        new(kind: :method, name: first.enclosing, file: first.file, line: first.enclosing_line,
            end_line: first.enclosing_end, def_kind: :def, direction: direction, sites: site_hashes)
      elsif first.owner
        new(kind: :site, name: "#{first.owner} (class body)", file: first.file, line: first.owner_line,
            end_line: first.owner_end, direction: direction, sites: site_hashes)
      else
        new(kind: :site, name: first.file, file: first.file, line: first.line, end_line: first.line,
            direction: direction, sites: site_hashes)
      end
    end

    def self.unresolved(label, sites: [], kind: :method)
      new(kind: kind, name: label, direction: :down, resolved: false, sites: sites)
    end

    def self.site_to_h(s)
      { "file" => s.file, "line" => s.line, "text" => s.text, "kind" => s.kind.to_s }
    end

    # Group call sites by their enclosing def, else enclosing class body, else by file+line.
    def self.group_sites(sites)
      sites.group_by do |s|
        if s.enclosing then [s.file, s.enclosing_line, s.enclosing]
        elsif s.owner then [s.file, s.owner_line, s.owner]
        else [s.file, s.line, nil]
        end
      end.values
    end

    def identity
      [name, file, line]
    end

    def root?
      parent.nil?
    end

    def depth
      d = 0
      n = self
      while (n = n.parent)
        d += 1
      end
      d
    end

    def dismissed?
      status == :dismissed
    end

    def confirmed?
      status == :confirmed
    end

    def unresolved?
      !resolved
    end

    # The bare method name to search for ("Billing::Order#total" -> "total"),
    # the constant for classes and class bodies, nil for bare file sites.
    def search_name
      case kind
      when :class then name
      when :site then name[/\A(\S+) \(class body\)\z/, 1]
      when :method
        if name =~ /[#.]([^#.]+)\z/
          Regexp.last_match(1)
        else
          name
        end
      end
    end

    def add_child(node)
      node.parent = self
      node.direction = :up if node.direction == :root
      children << node
      node
    end

    def remove_child(node)
      children.delete(node)
      node.parent = nil
    end

    def find_child(identity)
      children.find { |c| c.identity == identity }
    end

    def each_descendant(&blk)
      children.each do |c|
        blk.call(c)
        c.each_descendant(&blk)
      end
    end

    def to_h
      {
        "id" => id, "kind" => kind.to_s, "name" => name, "file" => file, "line" => line,
        "end_line" => end_line, "def_kind" => def_kind&.to_s, "direction" => direction.to_s,
        "sites" => sites, "status" => status.to_s, "note" => note, "expanded" => expanded,
        "resolved" => resolved, "children" => children.map(&:to_h)
      }
    end

    def self.from_h(h, parent: nil)
      node = new(
        id: h["id"], kind: h["kind"].to_sym, name: h["name"], file: h["file"], line: h["line"],
        end_line: h["end_line"], def_kind: h["def_kind"]&.to_sym, direction: (h["direction"] || "root").to_sym,
        sites: h["sites"] || [], status: (h["status"] || "unmarked").to_sym, note: h["note"],
        expanded: h.fetch("expanded", true), resolved: h.fetch("resolved", true), parent: parent
      )
      node.children = (h["children"] || []).map { |c| from_h(c, parent: node) }
      node
    end
  end

  class Session
    FORMAT = 1

    attr_accessor :roots, :root_path, :created_at, :updated_at, :path, :hide_dismissed,
                  :excludes, :default_excludes

    def initialize(root_path:, path: nil)
      @roots = []
      @root_path = root_path
      @path = path
      @created_at = Time.now
      @updated_at = Time.now
      @hide_dismissed = false
      @excludes = []
      @default_excludes = true
    end

    # Merges extra exclude globs (normalized). Returns true when anything changed.
    def add_excludes(globs)
      before = @excludes.dup
      @excludes = Config.normalize_globs(@excludes + globs)
      @excludes != before
    end

    def add_root(node)
      node.parent = nil
      node.direction = :root
      roots << node
      node
    end

    def remove(node)
      if node.parent
        node.parent.remove_child(node)
      else
        roots.delete(node)
      end
    end

    def all_nodes
      out = []
      roots.each do |r|
        out << r
        r.each_descendant { |n| out << n }
      end
      out
    end

    def find(id)
      all_nodes.find { |n| n.id == id }
    end

    def to_h
      {
        "format" => FORMAT, "root_path" => root_path, "created_at" => created_at.iso8601,
        "updated_at" => Time.now.iso8601, "hide_dismissed" => hide_dismissed,
        "excludes" => excludes, "default_excludes" => default_excludes,
        "roots" => roots.map(&:to_h)
      }
    end

    def save(target = path)
      raise Mls::Error, "no session path" unless target
      FileUtils.mkdir_p(File.dirname(target))
      tmp = "#{target}.tmp#{Process.pid}"
      File.write(tmp, JSON.pretty_generate(to_h))
      File.rename(tmp, target)
      @path = target
      @updated_at = Time.now
      target
    end

    def self.load(target, root_path: nil)
      h = JSON.parse(File.read(target))
      s = new(root_path: root_path || h["root_path"], path: target)
      s.created_at = Time.parse(h["created_at"]) rescue Time.now
      s.hide_dismissed = h["hide_dismissed"] ? true : false
      s.excludes = Config.normalize_globs(h["excludes"] || [])
      s.default_excludes = h.fetch("default_excludes", true) ? true : false
      s.roots = (h["roots"] || []).map { |r| Node.from_h(r) }
      s
    end

    def self.load_or_new(target, root_path:)
      File.exist?(target) ? load(target, root_path: root_path) : new(root_path: root_path, path: target)
    end
  end
end

# frozen_string_literal: true

module Mls
  # Automatically climbs the caller graph from a node, breadth-first, attaching every
  # caller as an "↑ called by" child. Pure logic: no terminal access.
  class Expander
    Result = Struct.new(:added, :max_depth_reached, :stopped, keyword_init: true)

    DEFAULT_MAX_NODES = 500

    # progress:  ->(depth:, added:, name:) called before each search
    # cancelled: -> Boolean, polled before each search
    def initialize(search, session, max_depth: nil, max_nodes: DEFAULT_MAX_NODES, progress: nil, cancelled: nil)
      @search = search
      @session = session
      @max_depth = max_depth
      @max_nodes = max_nodes
      @progress = progress
      @cancelled = cancelled
      @callers = {}
    end

    def expand_up(root)
      seen = @session.all_nodes.map(&:identity)
      seen << root.identity
      queue = [[root, 0]]
      added = 0
      deepest = 0
      stopped = nil

      until queue.empty?
        node, depth = queue.shift
        next if node.dismissed? || node.repeat || node.search_name.nil?
        if @max_depth && depth >= @max_depth
          stopped ||= :depth
          next
        end
        if @cancelled&.call
          stopped = :cancelled
          break
        end
        name = node.search_name
        @progress&.call(depth: depth, added: added, name: name)
        sites = callers_of(name)
        existing_children = node.children.map(&:identity)
        Node.group_sites(sites).each do |group|
          child = Node.from_sites(group, direction: :up)
          if existing_children.include?(child.identity)
            dup = node.find_child(child.identity)
            dup.merge_sites(child.sites)
            queue << [dup, depth + 1] unless dup.repeat
            next
          end
          if seen.include?(child.identity)
            child.repeat = true
            node.add_child(child)
          else
            node.add_child(child)
            seen << child.identity
            queue << [child, depth + 1]
          end
          added += 1
          deepest = [deepest, depth + 1].max
          if added >= @max_nodes
            stopped = :cap
            break
          end
        end
        node.expanded = true
        break if stopped == :cap
      end
      Result.new(added: added, max_depth_reached: deepest, stopped: stopped)
    end

    private

    def callers_of(name)
      @callers[name] ||= @search.find_callers(name).reject { |s| s.kind == :string }
    end
  end
end

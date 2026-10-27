# frozen_string_literal: true

require "test_helper"

class ExpanderTest < Minitest::Test
  include FixtureHelper

  def setup
    @search = fixture_search
    @session = Mls::Session.new(root_path: FIXTURE_ROOT)
    d = @search.find_definitions("total").find { |x| x.display == "Billing::Order#total" }
    @root = @session.add_root(Mls::Node.from_definition(d))
  end

  def expand(**opts)
    Mls::Expander.new(@search, @session, **opts).expand_up(@root)
  end

  def find(node, name)
    node.children.find { |c| c.name == name }
  end

  def test_unlimited_expansion_builds_the_whole_tree
    result = expand
    assert_nil result.stopped
    assert result.added > 5
    checkout = find(@root, "Checkout#summary")
    refute checkout.repeat
    show = find(checkout, "CheckoutsController#show")
    refute_nil show, "callers of callers are attached"
    assert_empty show.children, "nothing calls show in the fixture"

    pred = find(@root, "Billing::Order#total?")
    again = find(pred, "Checkout#summary")
    assert again.repeat, "converging path is marked as a repeat"
    assert_empty again.children

    body = find(@root, "Billing::Order (class body)")
    refute_nil body
    assert find(body, "CheckoutsController#load_order"), "class-body sites continue via class references"

    view = find(@root, "app/views/reports/index.html.erb")
    assert_empty view.children, "view sites are leaves"
    assert result.max_depth_reached >= 2
  end

  def test_depth_limit
    result = expand(max_depth: 1)
    assert_equal :depth, result.stopped
    assert_equal 1, result.max_depth_reached
    assert @root.children.all? { |c| c.children.empty? }
  end

  def test_node_cap
    result = expand(max_nodes: 2)
    assert_equal :cap, result.stopped
    assert_equal 2, result.added
    assert_equal 2, @session.all_nodes.size - 1
  end

  def test_cancel
    calls = 0
    cancelled = -> { calls > 1 }
    progress = ->(**_) { calls += 1 }
    result = expand(progress: progress, cancelled: cancelled)
    assert_equal :cancelled, result.stopped
    assert result.added.positive?
  end

  def test_dismissed_children_are_not_expanded
    expand(max_depth: 1)
    checkout = find(@root, "Checkout#summary")
    checkout.status = :dismissed
    expand
    assert_empty checkout.children
  end

  def test_second_run_adds_nothing
    expand
    assert_equal 0, expand.added
  end

  def test_string_hits_are_ignored
    sites = @search.find_callers("total")
    assert sites.none? { |s| s.kind == :string }, "fixture has no string hits; test guards the filter path"
    stub = Object.new
    def stub.find_callers(_name)
      [Mls::Search::CallSite.new(file: "x.rb", line: 1, text: '"total"', kind: :string, col: 0)]
    end
    r = Mls::Expander.new(stub, @session).expand_up(@root)
    assert_equal 0, r.added
  end
end

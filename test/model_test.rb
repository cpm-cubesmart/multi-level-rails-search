# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class ModelTest < Minitest::Test
  include FixtureHelper

  def build_session
    s = fixture_search
    sess = Mls::Session.new(root_path: FIXTURE_ROOT)
    d = s.find_definitions("total").find { |x| x.display == "Billing::Order#total" }
    root = sess.add_root(Mls::Node.from_definition(d))
    Mls::Node.group_sites(s.find_callers("total")).each do |group|
      root.add_child(Mls::Node.from_sites(group, direction: :up))
    end
    [sess, root]
  end

  def test_grouping_merges_sites_by_enclosing_def
    _sess, root = build_session
    checkout = root.children.find { |c| c.name == "Checkout#summary" }
    assert_equal 3, checkout.sites.size
    assert_equal %w[dot_call send send], checkout.sites.map { |s| s["kind"] }
    assert_equal 6, checkout.line
    assert_equal 11, checkout.end_line
    sites = root.children.select { |c| c.kind == :site }.map { |c| [c.name, c.line] }
    assert_includes sites, ["app/views/reports/index.html.erb", 2]
    assert_includes sites, ["Billing::Order (class body)", 4], "class-body call is attributed to the class"
    body = root.children.find { |c| c.name == "Billing::Order (class body)" }
    assert_equal "Billing::Order", body.search_name
  end

  def test_search_name
    assert_equal "total", Mls::Node.new(kind: :method, name: "Billing::Order#total").search_name
    assert_equal "build", Mls::Node.new(kind: :method, name: "Billing::Order.build").search_name
    assert_equal "sum", Mls::Node.new(kind: :method, name: "line_items.sum").search_name
    assert_equal "Billing::Order", Mls::Node.new(kind: :class, name: "Billing::Order").search_name
    assert_nil Mls::Node.new(kind: :site, name: "x.erb").search_name
  end

  def test_round_trip
    sess, root = build_session
    root.children.first.status = :dismissed
    root.children.first.note = "noise"
    root.children.last.expanded = false
    root.children.last.add_child(Mls::Node.unresolved("helper"))
    Dir.mktmpdir do |dir|
      path = File.join(dir, "nested", "session.json")
      sess.save(path)
      loaded = Mls::Session.load(path)
      assert_equal sess.to_h.reject { |k, _| k == "updated_at" }, loaded.to_h.reject { |k, _| k == "updated_at" }
      r = loaded.roots.first
      assert_equal :dismissed, r.children.first.status
      assert_equal "noise", r.children.first.note
      refute r.children.last.expanded
      assert r.children.last.children.first.unresolved?
      assert_same r, r.children.first.parent
      assert_equal 2, r.children.last.children.first.depth
    end
  end

  def test_remove_subtree
    sess, root = build_session
    n = root.children.size
    child = root.children.first
    child.add_child(Mls::Node.unresolved("x"))
    sess.remove(child)
    assert_equal n - 1, root.children.size
    refute sess.all_nodes.any? { |x| x.name == "x" }
    sess.remove(root)
    assert_empty sess.roots
  end

  def test_excludes_round_trip_and_defaults
    sess, = build_session
    sess.excludes = ["spec/**"]
    sess.default_excludes = false
    Dir.mktmpdir do |dir|
      path = File.join(dir, "s.json")
      sess.save(path)
      loaded = Mls::Session.load(path)
      assert_equal ["spec/**"], loaded.excludes
      refute loaded.default_excludes
      File.write(path, JSON.generate("root_path" => FIXTURE_ROOT, "roots" => []))
      old = Mls::Session.load(path)
      assert_equal [], old.excludes
      assert old.default_excludes
    end
    assert sess.add_excludes(["lib"])
    refute sess.add_excludes(["lib/"])
    assert_equal ["spec/**", "lib/**"], sess.excludes
  end

  def test_load_or_new
    Dir.mktmpdir do |dir|
      s = Mls::Session.load_or_new(File.join(dir, "s.json"), root_path: FIXTURE_ROOT)
      assert_empty s.roots
      assert_equal File.join(dir, "s.json"), s.path
    end
  end
end

# frozen_string_literal: true

require "test_helper"

class SearchTest < Minitest::Test
  include FixtureHelper

  def setup
    @s = fixture_search
  end

  def defs(name)
    @s.find_definitions(name).map { |d| [d.kind, d.display, d.file, d.line] }
  end

  def calls(name)
    @s.find_callers(name).map { |c| [c.kind, c.enclosing, c.file, c.line] }
  end

  def test_definitions_of_total
    d = defs("total")
    assert_includes d, [:def, "Billing::Order#total", "app/models/billing/order.rb", 12]
    assert_includes d, [:def, "Report#total", "app/models/report.rb", 3]
    assert_includes d, [:def, "Broken#total", "lib/broken.rb", 2]
    refute d.any? { |x| x[1].end_with?("total=") }, "setter must not match"
    refute d.any? { |x| x[1].end_with?("total?") }, "predicate must not match"
    refute d.any? { |x| x[2].start_with?("vendor/") }, "vendor is excluded"
  end

  def test_definition_ranges
    d = @s.find_definitions("total").find { |x| x.display == "Billing::Order#total" }
    assert_equal 12, d.start_line
    assert_equal 15, d.end_line
  end

  def test_macro_definitions
    assert_equal [[:scope, "Billing::Order.paid"]], defs("paid").map { |x| x[0..1] }
    assert_equal [[:delegate, "Billing::Order#email"]], defs("email").map { |x| x[0..1] }
    assert_equal [[:association, "Billing::Order#line_items"]], defs("line_items").map { |x| x[0..1] }
    assert_equal [[:attr, "Billing::Order#discount_code"]], defs("discount_code").map { |x| x[0..1] }
    assert_equal [[:def_self, "Billing::Order.build"]], defs("build").map { |x| x[0..1] }
    assert_equal [[:def, "Billing::Order.recent"]], defs("recent").map { |x| x[0..1] }
    assert_includes defs("summary").map { |x| x[0..1] }, [:define_method, "Billing::Order#summary"]
  end

  def test_setter_definitions_and_callers
    assert_equal [[:def, "Billing::Order#total=", "app/models/billing/order.rb", 22]], defs("total=")
    c = calls("total=")
    assert_includes c, [:dot_call, "Billing::Order#normalize", "app/models/billing/order.rb", 45]
    assert_includes c, [:dot_call, "Checkout#reset", "app/services/checkout.rb", 15]
    assert_equal 2, c.size
  end

  def test_callers_of_total
    c = calls("total")
    assert_includes c, [:dot_call, "Checkout#summary", "app/services/checkout.rb", 7]
    assert_includes c, [:send, "Checkout#summary", "app/services/checkout.rb", 8]
    assert_includes c, [:send, "Checkout#summary", "app/services/checkout.rb", 9]
    assert_includes c, [:block_symbol, "Report#grand_total", "app/models/report.rb", 8]
    assert_includes c, [:bare_call, "Billing::Order#total?", "app/models/billing/order.rb", 19]
    assert_includes c, [:bare_call, "Billing::Order#normalize", "app/models/billing/order.rb", 45]
    assert_includes c, [:dot_call, nil, "app/views/reports/index.html.erb", 2]
    assert_includes c, [:bare_call, "Broken#other", "lib/broken.rb", 7]
    lines = c.map { |x| [x[2], x[3]] }
    refute_includes lines, ["app/models/billing/order.rb", 12], "def line excluded"
    refute_includes lines, ["app/models/billing/order.rb", 13], "comment excluded"
    refute_includes lines, ["app/models/billing/order.rb", 18], "def total? excluded"
    refute_includes lines, ["app/services/checkout.rb", 10], "total? call is not a total call"
    refute_includes lines, ["app/services/checkout.rb", 11], "hash key total: is not a call"
    refute_includes lines, ["app/services/checkout.rb", 15], "setter call is not a getter call"
    refute_includes lines, ["app/views/reports/index.html.erb", 3], "erb comment excluded"
    refute c.any? { |x| x[2].start_with?("vendor/") }
  end

  def test_excludes
    c = calls("total")
    refute c.any? { |x| x[2].start_with?("spec/") || x[2].start_with?("test/") }, "test dirs excluded by default"

    cfg = fixture_config
    cfg.default_excludes = false
    files = Mls::Search.new(cfg).find_callers("total").map(&:file)
    assert_includes files, "spec/models/order_spec.rb"
    assert_includes files, "test/models/order_test.rb"

    cfg = fixture_config
    cfg.excludes = ["app/services/**"]
    enclosing = Mls::Search.new(cfg).find_callers("total").map(&:enclosing)
    refute_includes enclosing, "Checkout#summary"
  end

  def test_class_refs
    r = @s.find_class_refs("Billing::Order")
    assert_equal [["Billing::Order", "app/models/billing/order.rb", 4, 45]],
                 r[:definitions].map { |d| [d.display, d.file, d.line, d.end_line] }
    refs = r[:refs].map { |x| [x.enclosing, x.file, x.line] }
    assert_includes refs, ["CheckoutsController#load_order", "app/controllers/checkouts_controller.rb", 11]
    assert_includes refs, ["Report#grand_total", "app/models/report.rb", 8]
    assert_includes refs, [nil, "config/initializers/stuff.rb", 2]
    refute refs.any? { |x| x[1] == "app/models/billing/order.rb" }, "class line is a definition, not a ref"
  end

  def test_constant_names_route_to_class_search
    assert_equal :class_def, @s.find_definitions("Checkout").first.kind
    assert @s.find_callers("Checkout").all? { |c| c.kind == :const_ref }
  end

  def test_callees
    d = @s.find_definitions("total").find { |x| x.display == "Billing::Order#total" }
    labels = @s.find_callees(d.file, d.start_line, d.end_line).map(&:label)
    assert_equal %w[line_items line_items.sum apply_discount discount_code], labels
  end

  def test_strip_comment
    assert_equal "foo ", @s.strip_comment("foo # bar")
    assert_equal "", @s.strip_comment("  # only")
    assert_equal 'x = "a#b" ', @s.strip_comment('x = "a#b" # c')
    assert_equal "y = 'it''s' ", @s.strip_comment("y = 'it''s' # z")
    assert_equal 'puts "#{total}"', @s.strip_comment('puts "#{total}"')
  end

  def test_classify_call_priority
    assert_equal :dot_call, @s.classify_call("a.foo + foo", "foo")[0]
    assert_equal :bare_call, @s.classify_call("foo(1)", "foo")[0]
    assert_equal :bare_call, @s.classify_call("x = foo", "foo")[0]
    assert_equal :symbol, @s.classify_call("validate :foo", "foo")[0]
    assert_equal :string, @s.classify_call('m = "foo"', "foo")[0]
    assert_nil @s.classify_call("foo = 1", "foo")
    assert_nil @s.classify_call("subfoo", "foo")
    assert_nil @s.classify_call("@foo", "foo")
    assert_nil @s.classify_call("Foo::foo", "foo")
    assert_equal :bare_call, @s.classify_call("foo == 1", "foo")[0]
    assert_equal :dot_call, @s.classify_call("a&.foo", "foo")[0]
    assert_equal :dot_call, @s.classify_call("a.foo?", "foo?")[0]
    assert_equal :bare_call, @s.classify_call("save!", "save!")[0]
  end
end

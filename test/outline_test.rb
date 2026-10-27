# frozen_string_literal: true

require "test_helper"

class OutlineTest < Minitest::Test
  include FixtureHelper

  SRC = <<~RUBY
    module Billing
      class Order < ApplicationRecord
        scope :paid, -> { where(paid: true) }
        def total
          x = line_items.sum(&:price)
          helper(x) if x
          Foo::Bar.new.go
          self.class.where(id: 1)
          before_action :guard
          x
        end
        def self.build(attrs); new(attrs); end
        class << self
          def recent; paid; end
        end
      end
      class Admin::Report
        def ==(other); true; end
      end
    end
    def toplevel; end
  RUBY

  def outline
    @outline ||= Mls::Outline.parse(SRC)
  end

  def test_scopes_and_ranges
    names = outline.scopes.map { |s| [s.kind, s.name, s.start_line, s.end_line] }
    assert_includes names, [:module, "Billing", 1, 18]
    assert_includes names, [:class, "Order", 2, 14]
    assert_includes names, [:def, "total", 4, 10]
    assert_includes names, [:defs, "build", 12, 12]
    assert_includes names, [:sclass, "self", 13, 14]
    assert_includes names, [:def, "recent", 14, 14]
    assert_includes names, [:class, "Admin::Report", 17, 18]
    assert_includes names, [:def, "==", 18, 18]
    assert_includes names, [:def, "toplevel", 21, 21]
  end

  def test_enclosing_def_and_display_names
    assert_equal "Billing::Order#total", outline.display_name_at(6)
    assert_equal "Billing::Order.build", outline.display_name_at(12)
    assert_equal "Billing::Order.recent", outline.display_name_at(14)
    assert_equal "Billing::Admin::Report#==", outline.display_name_at(18)
    assert_equal "#toplevel", outline.display_name_at(21)
    assert_nil outline.display_name_at(3)
    assert_equal "Billing::Order", outline.qualified_owner(outline.enclosing_class(3))
  end

  def test_macro_display_name
    assert_equal "Billing::Order.paid", outline.macro_display_name(3, "paid", singleton: true)
    assert_equal "Billing::Order#email", outline.macro_display_name(3, "email")
  end

  def test_callees_in_def
    callees = outline.callees(4, 10)
    labels = callees.map(&:label)
    assert_includes labels, "line_items"
    assert_includes labels, "line_items.sum"
    assert_includes labels, "helper"
    assert_includes labels, "Foo::Bar"
    assert_includes labels, "Foo::Bar.new.go"
    assert_includes labels, "self.class.where"
    assert_includes labels, "before_action"
    assert_includes labels, ":guard"
    refute_includes labels, "x", "local variable reads are not calls"
    refute_includes labels, "paid", "outside the line range"
    kinds = callees.map { |c| [c.name, c.kind] }.to_h
    assert_equal :class, kinds["Foo::Bar"]
    assert_equal :symbol_ref, kinds["guard"]
  end

  def test_callee_dedupe_counts
    o = Mls::Outline.parse("def a\n  foo\n  foo\n  bar.foo\nend\n")
    c = o.callees(1, 5)
    foo = c.find { |x| x.name == "foo" && x.receiver.nil? }
    assert_equal 2, foo.count
    assert c.any? { |x| x.name == "foo" && x.receiver == "bar" }
  end

  def test_regex_fallback_on_syntax_error
    o = Mls::Outline.new(File.read(File.join(FIXTURE_ROOT, "lib/broken.rb")), path: "broken.rb")
    refute o.parsed
    assert_equal "Broken#other", o.display_name_at(7)
    assert_equal "Broken#total", o.display_name_at(3)
    assert_empty o.callees(1, 9)
  end

  def test_non_ruby_files_have_no_scopes
    o = Mls::Outline.new("<%= @order.total %>\n", path: "x.html.erb")
    refute o.parsed
    assert_empty o.scopes
  end

  def test_cache_by_mtime
    path = File.join(FIXTURE_ROOT, "app/models/report.rb")
    Mls::Outline.clear_cache
    a = Mls::Outline.for(path)
    b = Mls::Outline.for(path)
    assert_same a, b
  end
end

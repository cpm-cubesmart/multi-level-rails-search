# frozen_string_literal: true

require "test_helper"

class ExportTest < Minitest::Test
  def site(file, line, text, kind = "dot_call")
    { "file" => file, "line" => line, "text" => text, "kind" => kind }
  end

  def build
    sess = Mls::Session.new(root_path: "/app")
    root = sess.add_root(Mls::Node.new(kind: :method, name: "Billing::Order#total",
                                       file: "app/models/billing/order.rb", line: 5, def_kind: :def))
    a = root.add_child(Mls::Node.new(kind: :method, name: "Checkout#summary", file: "app/services/checkout.rb",
                                     line: 18, direction: :up, status: :confirmed, note: "main path",
                                     sites: [site("app/services/checkout.rb", 20, "amount = order.total")]))
    a.add_child(Mls::Node.new(kind: :method, name: "CheckoutsController#show",
                              file: "app/controllers/checkouts_controller.rb", line: 9, direction: :up,
                              sites: [site("app/controllers/checkouts_controller.rb", 11, "Checkout.new(order).summary")]))
    root.add_child(Mls::Node.new(kind: :site, name: "app/views/reports/index.html.erb",
                                 file: "app/views/reports/index.html.erb", line: 4, direction: :up,
                                 sites: [site("app/views/reports/index.html.erb", 4, "<%= order.total %>")]))
    root.add_child(Mls::Node.new(kind: :method, name: "Report#total", file: "app/models/report.rb", line: 3,
                                 direction: :up, status: :dismissed))
    root.add_child(Mls::Node.new(kind: :method, name: "LineItem#price", file: "app/models/line_item.rb", line: 7,
                                 def_kind: :attr, direction: :down))
    root.add_child(Mls::Node.unresolved("helper"))
    sess
  end

  EXPECTED = <<~TXT
    # Billing::Order#total  — app/models/billing/order.rb:5
    - ↑ called by Checkout#summary  — app/services/checkout.rb:18  [confirmed]
        app/services/checkout.rb:20: amount = order.total
        note: main path
      - ↑ called by CheckoutsController#show  — app/controllers/checkouts_controller.rb:9
          app/controllers/checkouts_controller.rb:11: Checkout.new(order).summary
    - ↑ called by app/views/reports/index.html.erb  [site]
        app/views/reports/index.html.erb:4: <%= order.total %>
    - ↓ calls LineItem#price  — app/models/line_item.rb:7  [attr]
    - ↓ calls helper  — (unresolved)
  TXT

  def test_render_excludes_dismissed_by_default
    assert_equal EXPECTED, Mls::Export.render(build)
  end

  def test_render_includes_dismissed_when_asked
    out = Mls::Export.render(build, include_dismissed: true)
    assert_includes out, "- ↑ called by Report#total  — app/models/report.rb:3  [dismissed]\n"
  end

  def test_multiple_roots_separated_by_blank_line
    sess = build
    sess.add_root(Mls::Node.new(kind: :class, name: "Checkout", file: "app/services/checkout.rb", line: 1,
                                def_kind: :class_def))
    out = Mls::Export.render(sess)
    assert_includes out, "\n\n# Checkout  — app/services/checkout.rb:1  [class]\n"
  end
end

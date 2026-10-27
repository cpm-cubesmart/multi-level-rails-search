# frozen_string_literal: true

require "test_helper"

class FinderTest < Minitest::Test
  include FixtureHelper

  def test_glob_semantics
    g = Mls::RubyGrep
    assert g.glob_match?("*.rb", "app/models/x.rb")
    refute g.glob_match?("*.rb", "app/models/x.erb")
    assert g.glob_match?("vendor/**", "vendor/gems/x.rb")
    refute g.glob_match?("vendor/**", "app/vendor/x.rb")
    assert g.glob_match?("db/schema.rb", "db/schema.rb")
    refute g.glob_match?("db/schema.rb", "x/db/schema.rb")
    assert g.glob_match?("Gemfile", "Gemfile")
  end

  def test_file_list_respects_config
    files = Mls::RubyGrep.files(fixture_config)
    assert_includes files, "app/models/report.rb"
    assert_includes files, "app/views/reports/index.html.erb"
    refute files.any? { |f| f.start_with?("vendor/") }
  end

  def test_ruby_grep_hits
    hits = Mls::RubyGrep.search("class Report", fixture_config)
    assert_equal [["app/models/report.rb", 1, 0]], hits.map { |h| [h.file, h.line, h.col] }
  end

  def test_rg_backend_matches_ruby_backend
    skip "set MLS_RG to a ripgrep binary to run" unless ENV["MLS_RG"]
    cfg = fixture_config
    a = Mls::Ripgrep.search("(^|[^A-Za-z0-9_])total([^A-Za-z0-9_]|$)", cfg).map(&:to_a)
    b = Mls::RubyGrep.search("(^|[^A-Za-z0-9_])total([^A-Za-z0-9_]|$)", cfg).map(&:to_a)
    assert_equal b, a
  end
end

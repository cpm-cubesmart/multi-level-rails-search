# frozen_string_literal: true

require "test_helper"

class ConfigTest < Minitest::Test
  def test_normalize_glob
    n = Mls::Config.method(:normalize_glob)
    assert_equal "spec/**", n.call("spec")
    assert_equal "spec/**", n.call("spec/")
    assert_equal "spec/**", n.call("./spec")
    assert_equal "app/assets/**", n.call("app/assets")
    assert_equal "spec/**", n.call("spec/**")
    assert_equal "*.rake", n.call("*.rake")
    assert_equal "db/schema.rb", n.call("db/schema.rb")
    assert_equal "spec/**/*_spec.rb", n.call("spec/**/*_spec.rb")
    assert_nil n.call("  ")
  end

  def test_normalize_globs_dedupes
    assert_equal ["spec/**", "lib/**"], Mls::Config.normalize_globs(["spec", "spec/", "lib", ""])
  end

  def test_apply_session
    c = Mls::Config.new(root: ".")
    s = Mls::Session.new(root_path: ".")
    s.excludes = ["spec/**"]
    s.default_excludes = false
    c.apply_session(s)
    assert_equal ["spec/**"], c.all_excludes
  end
end

# frozen_string_literal: true

require "test_helper"
require "mls/cli"
require "tmpdir"
require "stringio"

class CliTest < Minitest::Test
  include FixtureHelper

  def run_cli(*args)
    out = StringIO.new
    err = StringIO.new
    status = Mls::CLI.run(["--root", FIXTURE_ROOT, "--session", @session, *args], out: out, err: err)
    [status, out.string, err.string]
  end

  def setup
    @dir = Dir.mktmpdir
    @session = File.join(@dir, "s.json")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_default_excludes_hide_spec_and_test
    _, out, = run_cli("--callers", "total")
    refute_includes out, "spec/"
    refute_includes out, "test/"
    assert_includes out, "Checkout#summary"
  end

  def test_no_default_excludes_persists
    _, out, = run_cli("--no-default-excludes", "--callers", "total")
    assert_includes out, "spec/models/order_spec.rb"
    assert_includes out, "test/models/order_test.rb"
    assert_includes out, "vendor/gems/ignored.rb"
    _, out, = run_cli("--callers", "total")
    assert_includes out, "spec/models/order_spec.rb", "setting is remembered"
    _, out, = run_cli("--default-excludes", "--callers", "total")
    refute_includes out, "spec/"
  end

  def test_exclude_flag_is_remembered
    _, out, = run_cli("--exclude", "app/services", "--callers", "total")
    refute_includes out, "Checkout#summary"
    assert_equal ["app/services/**"], Mls::Session.load(@session).excludes
    _, out, = run_cli("--callers", "total")
    refute_includes out, "Checkout#summary", "exclude is remembered without the flag"
    _, out, = run_cli("--exclude", "app/services", "--exclude", "lib", "--definitions", "total")
    refute_includes out, "lib/broken.rb"
    assert_equal ["app/services/**", "lib/**"], Mls::Session.load(@session).excludes
  end

  def test_export_flag
    sess = Mls::Session.new(root_path: FIXTURE_ROOT, path: @session)
    sess.add_root(Mls::Node.new(kind: :method, name: "X#y", file: "x.rb", line: 1))
    sess.save
    status, out, = run_cli("--export", "-")
    assert_equal 0, status
    assert_equal "# X#y  — x.rb:1\n", out
  end
end

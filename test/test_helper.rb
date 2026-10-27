# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"
require "mls"

module FixtureHelper
  FIXTURE_ROOT = File.expand_path("fixtures/app", __dir__)

  def fixture_config
    Mls::Config.new(root: FIXTURE_ROOT)
  end

  def fixture_search
    Mls::Search.new(fixture_config)
  end
end

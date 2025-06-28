# frozen_string_literal: true

require "test_helper"

class TestSolidMCP < ActiveSupport::TestCase
  def test_that_it_has_a_version_number
    refute_nil ::SolidMCP::VERSION
  end

  def test_configuration_exists
    assert_instance_of SolidMCP::Configuration, SolidMCP.configuration
  end
end

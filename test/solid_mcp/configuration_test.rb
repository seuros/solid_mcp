# frozen_string_literal: true

require "test_helper"

module SolidMCP
  class ConfigurationTest < ActiveSupport::TestCase
    def setup
      @config = Configuration.new
    end

    def test_default_values
      assert_equal 200, @config.batch_size
      assert_equal 0.05, @config.flush_interval
      assert_equal 0.1, @config.polling_interval
      assert_equal 30, @config.max_wait_time
    end

    def test_delivered_retention_returns_duration
      assert_equal 3600.seconds, @config.delivered_retention_seconds
      assert_instance_of ActiveSupport::Duration, @config.delivered_retention_seconds
    end

    def test_undelivered_retention_returns_duration
      assert_equal 86400.seconds, @config.undelivered_retention_seconds
      assert_instance_of ActiveSupport::Duration, @config.undelivered_retention_seconds
    end

    def test_configuration_is_mutable
      @config.batch_size = 500
      assert_equal 500, @config.batch_size

      @config.flush_interval = 0.1
      assert_equal 0.1, @config.flush_interval

      @config.polling_interval = 0.5
      assert_equal 0.5, @config.polling_interval

      @config.max_wait_time = 60
      assert_equal 60, @config.max_wait_time
    end

    def test_retention_can_be_set_in_seconds
      @config.delivered_retention = 7200
      assert_equal 7200.seconds, @config.delivered_retention

      @config.undelivered_retention = 172800
      assert_equal 172800.seconds, @config.undelivered_retention
    end
  end
end
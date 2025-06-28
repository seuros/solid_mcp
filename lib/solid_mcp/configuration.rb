# frozen_string_literal: true

module SolidMCP
  class Configuration
    attr_accessor :batch_size, :flush_interval, :delivered_retention, 
                  :undelivered_retention, :polling_interval, :max_wait_time, :logger

    def initialize
      @batch_size = 200
      @flush_interval = 0.05 # 50ms
      @polling_interval = 0.1 # 100ms
      @max_wait_time = 30 # 30 seconds
      @delivered_retention = 3600 # 1 hour in seconds
      @undelivered_retention = 86400 # 24 hours in seconds
      @logger = default_logger
    end

    def delivered_retention_seconds
      @delivered_retention.seconds
    end

    def undelivered_retention_seconds
      @undelivered_retention.seconds
    end

    private

    def default_logger
      if defined?(Rails) && Rails.respond_to?(:logger)
        Rails.logger
      else
        require 'active_support/tagged_logging'
        ActiveSupport::TaggedLogging.new(::Logger.new($stdout))
      end
    end
  end
end
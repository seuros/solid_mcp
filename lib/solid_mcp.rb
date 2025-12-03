# frozen_string_literal: true

require_relative "solid_mcp/version"
require_relative "solid_mcp/configuration"
require_relative "solid_mcp/logger"
require_relative "solid_mcp/engine" if defined?(Rails)

# Always load core components
require_relative "solid_mcp/message_writer"
require_relative "solid_mcp/subscriber"
require_relative "solid_mcp/cleanup_job"

# Load test components in test environment
if ENV["RAILS_ENV"] == "test"
  require_relative "solid_mcp/test_pub_sub"
end

# Always require pub_sub after environment-specific components
require_relative "solid_mcp/pub_sub"

module SolidMCP
  class Error < StandardError; end

  class << self
    attr_accessor :configuration

    def configure
      self.configuration ||= Configuration.new
      yield(configuration) if block_given?
    end

    def configured?
      configuration.present?
    end
  end

  # Initialize with default configuration
  self.configuration = Configuration.new
end

# Load native speedup AFTER module is defined (optional - gracefully falls back to pure Ruby)
require_relative "solid_mcp/native_speedup"

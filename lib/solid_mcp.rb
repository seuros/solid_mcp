# frozen_string_literal: true

require_relative "solid_mcp/version"
require_relative "solid_mcp/configuration"
require_relative "solid_mcp/engine" if defined?(Rails)

# Load required components based on environment
if defined?(Rails) && Rails.env.test?
  require_relative "solid_mcp/test_pub_sub"
else
  require_relative "solid_mcp/message_writer"
  require_relative "solid_mcp/subscriber"
  require_relative "solid_mcp/cleanup_job"
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

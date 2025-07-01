# frozen_string_literal: true

# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [File.expand_path("../db/migrate", __dir__)]
require "rails/test_help"

# Load solid_mcp
require "solid_mcp"

# Run migrations on the primary database
ActiveRecord::MigrationContext.new(File.expand_path("../db/migrate", __dir__)).migrate

# Load models manually for now
require_relative "../app/models/solid_mcp/record"
require_relative "../app/models/solid_mcp/message"

# Test helper methods
module SolidMCP
  module TestHelper
    def wait_for_condition(timeout = 2)
      start_time = Time.now
      while Time.now - start_time < timeout
        return true if yield
        sleep 0.01
      end
      false
    end
  end
end

# Include test helper in all tests
class ActiveSupport::TestCase
  include SolidMCP::TestHelper
end

# Ensure SolidMCP is configured for tests
SolidMCP.configure do |config|
  config.logger = Rails.logger
end
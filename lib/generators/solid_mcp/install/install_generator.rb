# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module SolidMCP
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      def create_migration_file
        migration_template "create_solid_mcp_messages.rb.erb", "db/migrate/create_solid_mcp_messages.rb"
      end

      def add_initializer
        template "solid_mcp.rb", "config/initializers/solid_mcp.rb"
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
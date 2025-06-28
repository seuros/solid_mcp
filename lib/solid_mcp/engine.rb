# frozen_string_literal: true

module SolidMCP
  class Engine < ::Rails::Engine
    isolate_namespace SolidMCP

    config.generators do |g|
      g.test_framework :minitest
    end

    # Ensure app/models is in the autoload paths
    config.autoload_paths << root.join("app/models")

    initializer "solid_mcp.migrations" do
      config.paths["db/migrate"].expanded.each do |expanded_path|
        Rails.application.config.paths["db/migrate"] << expanded_path
      end
    end

    initializer "solid_mcp.configuration" do
      # Set default configuration if not already configured
      SolidMCP.configuration ||= Configuration.new
    end

    initializer "solid_mcp.start_message_writer" do
      # Start the message writer in non-test environments
      unless Rails.env.test?
        Rails.application.config.to_prepare do
          SolidMCP::MessageWriter.instance
        end
      end
    end
  end
end
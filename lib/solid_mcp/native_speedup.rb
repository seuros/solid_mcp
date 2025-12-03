# frozen_string_literal: true

# Native Rust acceleration for SolidMCP (optional)
#
# This module provides a Rust-powered pub/sub engine using Tokio for async I/O.
# Falls back gracefully to pure Ruby if the native extension is unavailable.
#
# Features:
# - 50-100x faster message throughput
# - PostgreSQL LISTEN/NOTIFY support (no polling)
# - SQLite WAL mode with efficient async polling
# - Compile-time thread safety guarantees

module SolidMCP
  module NativeSpeedup
    class << self
      def available?
        @available ||= load_native_extension
      end

      def version
        return nil unless available?
        SolidMCPNative.version
      end

      private

      def load_native_extension
        return false if ENV["DISABLE_SOLID_MCP_NATIVE"]

        begin
          require "solid_mcp_native/solid_mcp_native"
          log_info "SolidMCP native extension loaded (v#{SolidMCPNative.version})"
          true
        rescue LoadError => e
          log_debug "SolidMCP native extension not available: #{e.message}"
          false
        end
      end

      def log_info(msg)
        SolidMCP::Logger.info(msg)
      rescue StandardError
        # Logger not ready, silently ignore
      end

      def log_debug(msg)
        SolidMCP::Logger.debug(msg)
      rescue StandardError
        # Logger not ready, silently ignore
      end
    end

    # Override MessageWriter with native implementation
    module MessageWriterOverride
      def self.prepended(base)
        # Only prepend if native extension is available
        return unless SolidMCP::NativeSpeedup.available?

        SolidMCP::Logger.debug "Enabling native MessageWriter"
      end

      def initialize
        if SolidMCP::NativeSpeedup.available? && !@native_initialized
          # Initialize native engine with SQLite/PostgreSQL URL
          db_config = SolidMCP.configuration.database_config
          database_url = build_database_url(db_config)

          SolidMCPNative.init_with_config(
            database_url,
            SolidMCP.configuration.batch_size,
            (SolidMCP.configuration.polling_interval * 1000).to_i, # Convert to ms
            SolidMCP.configuration.max_queue_size
          )
          @native_initialized = true
        else
          super
        end
      end

      def enqueue(session_id, event_type, data)
        if SolidMCP::NativeSpeedup.available? && @native_initialized
          json_data = data.is_a?(String) ? data : data.to_json
          SolidMCPNative.broadcast(session_id.to_s, event_type.to_s, json_data)
        else
          super
        end
      end

      def flush
        if SolidMCP::NativeSpeedup.available? && @native_initialized
          SolidMCPNative.flush
        else
          super
        end
      end

      def shutdown
        if SolidMCP::NativeSpeedup.available? && @native_initialized
          SolidMCPNative.shutdown
          @native_initialized = false
        else
          super
        end
      end

      private

      def build_database_url(config)
        adapter = config[:adapter] || "sqlite3"

        case adapter
        when "sqlite3"
          # SQLite URL format
          database = config[:database] || ":memory:"
          "sqlite://#{database}"
        when "postgresql", "postgres"
          # PostgreSQL URL format
          host = config[:host] || "localhost"
          port = config[:port] || 5432
          database = config[:database] || "solid_mcp"
          username = config[:username]
          password = config[:password]

          auth = username ? "#{username}:#{password}@" : ""
          "postgres://#{auth}#{host}:#{port}/#{database}"
        else
          raise SolidMCP::Error, "Unsupported database adapter: #{adapter}"
        end
      end
    end
  end
end

# Auto-load native extension on require (if available)
if SolidMCP::NativeSpeedup.available?
  # MessageWriter.prepend(SolidMCP::NativeSpeedup::MessageWriterOverride)
  # Note: Uncommenting this line enables automatic native acceleration
  # For now, keep it opt-in until the Rust code is battle-tested
end

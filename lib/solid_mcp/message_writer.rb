# frozen_string_literal: true

require "singleton"
require "concurrent"

module SolidMCP
  class MessageWriter
    include Singleton

    def initialize
      @queue = Queue.new
      @shutdown = Concurrent::AtomicBoolean.new(false)
      @thread = nil
      start_thread
    end

    # Called by publish API - non-blocking
    def enqueue(session_id, event_type, data)
      @queue << {
        session_id: session_id,
        event_type: event_type,
        data: data.is_a?(String) ? data : data.to_json,
        created_at: Time.current
      }
    end

    # Blocks until thread has flushed everything
    def shutdown
      @shutdown.make_true
      @thread&.join
    end

    private

    def start_thread
      @thread = Thread.new { run_loop }
    end

    def run_loop
      loop do
        break if @shutdown.true? && @queue.empty?

        batch = drain_batch
        if batch.any?
          write_batch(batch)
        else
          sleep SolidMCP.configuration.flush_interval
        end
      end
    rescue => e
      Rails.logger.error "SolidMCP::MessageWriter error: #{e.message}" if defined?(Rails)
      retry unless @shutdown.true?
    end

    def drain_batch
      batch = []
      batch_size = SolidMCP.configuration.batch_size

      # Try to get first item (non-blocking)
      begin
        batch << @queue.pop(true)
      rescue ThreadError
        return batch
      end

      # Get remaining items up to batch size
      while batch.size < batch_size
        begin
          batch << @queue.pop(true)
        rescue ThreadError
          break
        end
      end

      batch
    end

    def write_batch(batch)
      return if batch.empty?

      # Use raw SQL for maximum performance
      values = batch.map do |msg|
        conn = ActiveRecord::Base.connection
        [
          conn.quote(msg[:session_id]),
          conn.quote(msg[:event_type]),
          conn.quote(msg[:data]),
          conn.quote(msg[:created_at].utc.to_s(:db))
        ].join(",")
      end

      sql = <<-SQL
        INSERT INTO solid_mcp_messages (session_id, event_type, data, created_at)
        VALUES #{values.map { |v| "(#{v})" }.join(",")}
      SQL

      ActiveRecord::Base.connection.execute(sql)
    rescue => e
      Rails.logger.error "SolidMCP::MessageWriter batch write error: #{e.message}" if defined?(Rails)
      # Could implement retry logic or dead letter queue here
    end
  end
end
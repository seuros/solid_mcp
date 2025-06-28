# frozen_string_literal: true

require "singleton"
require "concurrent"

module SolidMCP
  class MessageWriter
    include Singleton
    
    # Reset the singleton (for testing only)
    def self.reset!
      @singleton__instance__ = nil
    end

    def initialize
      @queue = Queue.new
      @shutdown = Concurrent::AtomicBoolean.new(false)
      @executor = Concurrent::ThreadPoolExecutor.new(
        min_threads: 1,
        max_threads: 1,  # Single thread for ordered writes
        max_queue: 0,    # Unbounded queue
        fallback_policy: :caller_runs
      )
      start_worker
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

    # Blocks until executor has flushed everything
    def shutdown
      # Process any remaining messages in the queue
      flush if @executor.running?
      
      @shutdown.make_true
      @executor.shutdown
      @executor.wait_for_termination(10) # Wait up to 10 seconds
    end

    # Force flush any pending messages (useful for tests)
    def flush
      return unless @executor.running?
      
      # Add a marker and wait for it to be processed
      processed = Concurrent::CountDownLatch.new(1)
      @queue << { flush_marker: processed }
      
      # Wait up to 1 second for flush to complete
      processed.wait(1)
    end

    private

    def start_worker
      @executor.post do
        begin
          SolidMCP::Logger.debug "MessageWriter worker thread started" if ENV["DEBUG_SOLID_MCP"]
          run_loop
        rescue => e
          SolidMCP::Logger.error "MessageWriter worker thread crashed: #{e.message}"
          SolidMCP::Logger.error e.backtrace.join("\n")
        end
      end
    end

    def run_loop
      loop do
        break if @shutdown.true? && @queue.empty?

        batch = drain_batch
        if batch.any?
          SolidMCP::Logger.debug "MessageWriter processing batch of #{batch.size} messages" if ENV["DEBUG_SOLID_MCP"]
          write_batch(batch)
        else
          sleep SolidMCP.configuration.flush_interval
        end
      end
    rescue => e
      SolidMCP::Logger.error "SolidMCP::MessageWriter error: #{e.message}"
      retry unless @shutdown.true?
    end

    def drain_batch
      batch = []
      batch_size = SolidMCP.configuration.batch_size
      flush_markers = []

      # Try to get first item (non-blocking)
      begin
        item = @queue.pop(true)
        # Handle flush markers
        if item.is_a?(Hash) && item[:flush_marker]
          flush_markers << item[:flush_marker]
        else
          batch << item
        end
      rescue ThreadError
        # Signal any flush markers we've collected
        flush_markers.each(&:count_down)
        return batch
      end

      # Get remaining items up to batch size
      while batch.size < batch_size
        begin
          item = @queue.pop(true)
          # Handle flush markers
          if item.is_a?(Hash) && item[:flush_marker]
            flush_markers << item[:flush_marker]
          else
            batch << item
          end
        rescue ThreadError
          break
        end
      end

      # Signal any flush markers we've collected
      flush_markers.each(&:count_down)
      batch
    end

    def write_batch(batch)
      return if batch.empty?

      # Use raw SQL for maximum performance
      ActiveRecord::Base.connection_pool.with_connection do |conn|
        values = batch.map do |msg|
          [
            conn.quote(msg[:session_id]),
            conn.quote(msg[:event_type]),
            conn.quote(msg[:data]),
            conn.quote(msg[:created_at].utc.to_fs(:db))
          ].join(",")
        end

        sql = <<-SQL
          INSERT INTO solid_mcp_messages (session_id, event_type, data, created_at)
          VALUES #{values.map { |v| "(#{v})" }.join(",")}
        SQL

        conn.execute(sql)
      end
    rescue => e
      SolidMCP::Logger.error "SolidMCP::MessageWriter batch write error: #{e.message}"
      # Could implement retry logic or dead letter queue here
    end
  end
end
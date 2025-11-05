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
      @queue = SizedQueue.new(SolidMCP.configuration.max_queue_size)
      @shutdown = Concurrent::AtomicBoolean.new(false)
      @dropped_count = Concurrent::AtomicFixnum.new(0)
      @worker_ready = Concurrent::CountDownLatch.new(1)
      @executor = Concurrent::ThreadPoolExecutor.new(
        min_threads: 1,
        max_threads: 1,  # Single thread for ordered writes
        max_queue: 0,    # Unbounded queue
        fallback_policy: :caller_runs
      )
      start_worker
      # Wait for worker thread to be ready (with short timeout)
      # Using 0.1s is enough for worker to start, avoids 1s delay per test
      @worker_ready.wait(0.1)
    end

    # Called by publish API - non-blocking with backpressure
    def enqueue(session_id, event_type, data)
      message = {
        session_id: session_id,
        event_type: event_type,
        data: data.is_a?(String) ? data : data.to_json,
        created_at: Time.now.utc
      }

      # Try non-blocking push with backpressure
      begin
        @queue.push(message, true) # non-blocking
        true
      rescue ThreadError
        # Queue full - drop message and log
        @dropped_count.increment
        SolidMCP::Logger.warn "SolidMCP queue full (#{SolidMCP.configuration.max_queue_size}), dropped message for session #{session_id}"
        false
      end
    end

    # Get count of dropped messages
    def dropped_count
      @dropped_count.value
    end

    # Blocks until executor has flushed everything
    def shutdown
      SolidMCP::Logger.info "SolidMCP::MessageWriter shutting down, #{@queue.size} messages pending"

      # Mark as shutting down (worker will exit after draining queue)
      @shutdown.make_true

      # Wait for executor to finish processing
      @executor.shutdown
      @executor.wait_for_termination(SolidMCP.configuration.shutdown_timeout)

      if @queue.size > 0
        SolidMCP::Logger.warn "SolidMCP::MessageWriter shutdown timeout, #{@queue.size} messages not written"
      end
    end

    # Force flush any pending messages (useful for tests)
    def flush
      return unless @executor.running?

      # Add a marker and wait for it to be processed
      processed = Concurrent::CountDownLatch.new(1)

      # Use blocking push for flush marker (not subject to queue limits)
      begin
        @queue.push({ flush_marker: processed }, false) # blocking
      rescue ThreadError
        # Queue is shutting down
        return
      end

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
      # Signal that worker is ready
      @worker_ready.count_down

      loop do
        break if @shutdown.true? && @queue.empty?

        batch = drain_batch
        if batch.any?
          SolidMCP::Logger.debug "MessageWriter processing batch of #{batch.size} messages" if ENV["DEBUG_SOLID_MCP"]
          write_batch(batch)
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

      # Get first item with timeout (blocking)
      item = @queue.pop(false) rescue nil # blocking pop, returns nil on shutdown

      return batch unless item

      # Handle flush markers
      if item.is_a?(Hash) && item[:flush_marker]
        flush_markers << item[:flush_marker]
      else
        batch << item
      end

      # Get remaining items up to batch size (non-blocking)
      while batch.size < batch_size
        begin
          item = @queue.pop(true) # non-blocking
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

      # Use ActiveRecord insert_all for safety and database portability
      records = batch.map do |msg|
        {
          session_id: msg[:session_id],
          event_type: msg[:event_type],
          data: msg[:data],
          created_at: msg[:created_at]
        }
      end

      SolidMCP::Message.insert_all(records)
    rescue => e
      SolidMCP::Logger.error "SolidMCP::MessageWriter batch write error: #{e.message}"
      # Could implement retry logic or dead letter queue here
    end
  end
end
# frozen_string_literal: true

require "concurrent/atomic/atomic_boolean"
require "concurrent/timer_task"

module SolidMCP
  class Subscriber
    def initialize(session_id, callbacks)
      @session_id = session_id
      @callbacks = callbacks
      @running = Concurrent::AtomicBoolean.new(false)
      @last_message_id = 0
      @timer_task = nil
      @max_retries = ENV["RAILS_ENV"] == "test" ? 3 : Float::INFINITY
      @retry_count = 0
    end

    def start
      return if @running.true?

      @running.make_true
      @retry_count = 0
      
      @timer_task = Concurrent::TimerTask.new(
        execution_interval: SolidMCP.configuration.polling_interval,
        timeout_interval: 30,
        run_now: true
      ) do
        poll_once
      end
      
      @timer_task.execute
    end

    def stop
      @running.make_false
      @timer_task&.shutdown
      @timer_task&.wait_for_termination(5)
    end

    private

    def poll_once
      return unless @running.true?
      
      # Ensure connection in thread
      SolidMCP::Message.connection_pool.with_connection do
        # In test environment, ensure schema is visible to this thread
        if ENV["RAILS_ENV"] == "test" && defined?(SolidMCP::ThreadDatabaseHelper)
          SolidMCP::ThreadDatabaseHelper.ensure_schema_visible
        end
        
        messages = fetch_new_messages
        if messages.any?
          process_messages(messages)
          mark_delivered(messages)
          @retry_count = 0
        end
      end
    rescue => e
      @retry_count += 1
      SolidMCP::Logger.error "SolidMCP::Subscriber error for session #{@session_id}: #{e.message} (retry #{@retry_count}/#{@max_retries})"
      
      if @retry_count >= @max_retries && @max_retries != Float::INFINITY
        SolidMCP::Logger.error "SolidMCP::Subscriber max retries reached for session #{@session_id}, stopping"
        stop
      end
    end

    def fetch_new_messages
      SolidMCP::Message
        .for_session(@session_id)
        .undelivered
        .after_id(@last_message_id)
        .order(:id)
        .limit(100)
        .to_a
    end

    def process_messages(messages)
      messages.each do |message|
        @callbacks.each do |callback|
          callback.call({
            event_type: message.event_type,
            data: message.data,  # data is already a JSON string from the database
            id: message.id
          })
        rescue => e
          SolidMCP::Logger.error "SolidMCP callback error: #{e.message}"
        end
        @last_message_id = message.id
      end
    end

    def mark_delivered(messages)
      SolidMCP::Message.mark_delivered(messages.map(&:id))
    end
  end
end
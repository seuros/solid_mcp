# frozen_string_literal: true

module SolidMCP
  class CleanupJob < ActiveJob::Base
    def perform
      SolidMCP::Message.cleanup(
        delivered_retention: SolidMCP.configuration.delivered_retention,
        undelivered_retention: SolidMCP.configuration.undelivered_retention
      )
    end
  end
end
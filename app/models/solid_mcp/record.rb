# frozen_string_literal: true

module SolidMCP
  class Record < ActiveRecord::Base
    self.abstract_class = true

    # In tests, we configure the connection directly
    # In production, you can use connects_to
    if Rails.env.test?
      establish_connection :solid_mcp
    end
  end
end
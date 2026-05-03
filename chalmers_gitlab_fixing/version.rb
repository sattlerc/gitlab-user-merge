# frozen_string_literal: true

module ChalmersGitlabFixing
  module Version
    VERSIONS = %i[source target].to_set

    def self.format_arrow(versions, &block)
      block = proc(&:to_s) if block.nil?

      "#{block.call(versions[:source])} → #{block.call(versions[:target])}"
    end

    # For chronological sorting.
    def self.order(version)
      {
        source: 1,
        target: 0
      }.fetch(version)
    end

    # Source comes first.
    def self.of_pair((source, target))
      {
        source: source,
        target: target
      }
    end

    def self.string(version)
      {
        source: '_source',
        target: '_target'
      }.fetch(version)
    end

    def self.sql(version)
      "_#{string(version)}"
    end

    def self.sql_user_id(version)
      "_#{string(version)}_user_id"
    end
  end
end

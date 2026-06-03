# frozen_string_literal: true

# TODO: replace load with require_relative.
load 'lib/general.rb'
load 'lib/deserialization.rb'
load 'lib/json.rb'
load 'lib/sql.rb'
load 'lib/version.rb'
load 'lib/models.rb'

# Reads from PATH_USER_MAPPING.
load 'lib/user_mapping.rb'

# Writes to and reads from PATH_COLUMN_CLASSIFICATION.
load 'lib/column_classification.rb'

load 'lib/chronologicity.rb'
load 'lib/resolution.rb'
load 'lib/uniqueness_check.rb'
load 'lib/replacement.rb'
load 'lib/personal_projects.rb'

# Unused in production.
# require_relative 'lib/membership'

load 'lib/text.rb'

module GitlabUserMerge
  class Instance
    include SQLExecution
    include Models
    include UserMapping
    include WithColumnClassification
    include Chronologicity
    include WithResolutions
    include UniquenessCheck
    include Replacement
    include Text

    PATH_COLUMN_CONFLICTS_BY_VERSION_USER_ID = ENV.fetch('PATH_COLUMN_CONFLICTS_BY_VERSION_USER_ID', 'column_conflicts_by_version_user_id.txt')
    PATH_COLUMN_CONFLICTS_BY_TABLE_AND_COLUMN = ENV.fetch('PATH_COLUMN_CONFLICTS_BY_TABLE_AND_COLUMN', 'column_conflicts_by_table_and_column.txt')

    def perform_column_classification
      ColumnClassifier.new.scan_and_write
    end

    def check_text_and_json_columns
      check_text_array_columns
      check_text_columns
      check_json_columns
    end

    # check_for_unresolved_conflicts

    def print_conflict_resolutions
      File.open(PATH_COLUMN_CONFLICTS_BY_VERSION_USER_ID, 'w') do |file|
        print_column_conflicts_by_version_user_id(file: file, resolution: true)
      end
      File.open(PATH_COLUMN_CONFLICTS_BY_TABLE_AND_COLUMN, 'w') do |file|
        print_column_conflicts_by_table_and_column(file: file, resolution: true)
      end
    end

    def perform_conflict_resolution(perform: false)
      check_for_unresolved_conflicts
      # TODO
    end

    def perform_user_merge(perform: false)
      # TODO
    end

    def perform_personal_projects_transfer(perform: false)
      report_personal_projects
      check_personal_projects_for_conflict
      return unless perform

      transfer_personal_projects
      check_personal_projects_clear
      refresh_project_authorizations
      refresh_user_highest_roles
    end

    def delete_source_users(perform: false)
      return unless perform

      duplicated_users.each do |user|
        user.destroy!
      end
    end
  end
end

#require_relative 'lib/text'

module C
  include GitlabUserMerge

  instance = Instance.new
  instance.check_text_array_columns

  # File.open('/home/sattler/mnt/chronicity.txt', 'w') do |file|
  #   instance.check(file: file, strict: false)
  # end

  # instance.check_for_unresolved_conflicts
  # instance.print_resolution_queries

  # instance.report_namespace_projects
  # instance.check_namespace_projects
  # instance.transfer_personal_projects

  # File.open('/home/sattler/mnt/column_conflicts_by_user_id.txt', 'w') do |file|
  #   instance.print_column_conflicts_by_version_user_id(file: file, resolution: true)
  # end
  # File.open('/home/sattler/mnt/column_conflicts_by_table_and_column.txt', 'w') do |file|
  #   instance.print_column_conflicts_by_table_and_column(file: file, resolution: true)
  # end
  # instance.column_conflicts_by_table
  # instance.print_column_conflicts_by_table_and_column
  # instance.print_column_conflicts_by_version_user_id(resolution: true)

  # instance.print_relevant_unique_index
  # instance.print_conflict_columns
  # instance.print_resolve_conflicts(resolution: false)
end

"
Dir.chdir('/home/sattler/mnt/ruby')
load 'gitlab_user_merge.rb'
"

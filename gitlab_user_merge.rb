# frozen_string_literal: true

# Constants.
module GitlabUserMerge
  # Specification of the user merge.
  # This is a JSON object sending source user ids (merge source) to target user id (merge target).
  # All of these ids are required to be pairwise distinct.
  # Read-only.
  PATH_USER_MAPPING = ENV.fetch('PATH_USER_MAPPING', 'user-mapping.json')

  # Storage of the column classification.
  # Write and read.
  PATH_COLUMN_CLASSIFICATION = ENV.fetch('PATH_COLUMN_CLASSIFICATION', 'column-classification.json')

  # Column classification report.
  # Write-only.
  PATH_REPORT_COLUMN_CLASSIFICATION = ENV.fetch('PATH_REPORT_COLUMN_CLASSIFICATION', 'column-classification.txt')

  # Reports of analysis of occurrence of duplicated user ids and usernames in text and JSON columns.
  # Write-only.
  PATH_REPORT_COLUMN_JSON = ENV.fetch('PATH_REPORT_COLUMN_JSON', 'columns-json-report.txt')
  PATH_REPORT_COLUMN_TEXT = ENV.fetch('PATH_REPORT_COLUMN_TEXT', 'columns-text-report.txt')
  PATH_REPORT_COLUMN_TEXT_ARRAY = ENV.fetch('PATH_REPORT_COLUMN_TEXT_ARRAY', 'columns-text-array-report.txt')

  # Directories for storing the evidence of the above.
  # Write-only.
  DIR_COLUMN_JSON = ENV.fetch('DIR_COLUMN_JSON', 'columns-json')
  DIR_COLUMN_TEXT = ENV.fetch('DIR_COLUMN_TEXT', 'columns-text')

  # Reports of conflicts to user merging.
  # Write-only.
  PATH_REPORT_COLUMN_CONFLICTS_BY_VERSION_USER_ID = ENV.fetch('PATH_COLUMN_CONFLICTS_BY_VERSION_USER_ID',
                                                              'column-conflicts-by-user-mapping.txt')
  PATH_REPORT_COLUMN_CONFLICTS_BY_TABLE_AND_COLUMN = ENV.fetch('PATH_COLUMN_CONFLICTS_BY_TABLE_AND_COLUMN',
                                                               'column-conflicts-by-table-and-column.txt')

  # Report of personal projects for users involved in merging.
  # Write-only.
  PATH_REPORT_PERSONAL_PROJECTS = ENV.fetch('PATH_REPORT_PERSONAL_PROJECTS', 'personal-projects.txt')

  # Database query logging.
  # Useful for dry runs.
  # Write-only.
  PATH_REPORT_QUERIES = ENV.fetch('PATH_REPORT_QUERIES', 'database-queries.txt')

  load "#{__dir__}/lib/general.rb"
  load "#{__dir__}/lib/deserialization.rb"
  load "#{__dir__}/lib/json.rb"
  load "#{__dir__}/lib/sql.rb"
  load "#{__dir__}/lib/version.rb"
  load "#{__dir__}/lib/models.rb"

  # Reads from PATH_USER_MAPPING.
  load "#{__dir__}/lib/user_mapping.rb"

  load "#{__dir__}/lib/text.rb"
  load "#{__dir__}/lib/column_classification.rb"
  load "#{__dir__}/lib/chronologicity.rb"
  load "#{__dir__}/lib/resolution.rb"
  load "#{__dir__}/lib/uniqueness_check.rb"
  load "#{__dir__}/lib/replacement.rb"
  load "#{__dir__}/lib/personal_projects.rb"

  # Not used by tool.
  # require_relative "#{__dir__}/lib/membership"

  # High-level interface to user merging.
  class Tool
    include SQLExecution
    include Models
    include UserMapping
    include Text
    include WithColumnClassification
    include Chronologicity
    include WithResolutions
    include UniquenessCheck
    include Replacement
    include PersonalProjects

    def perform_user_merge(path_report_queries: PATH_REPORT_QUERIES, perform: false, abort: true)
      check_personal_projects_clear

      with_executor(path_report_queries: path_report_queries, perform: perform, abort: abort) do |executor|
        executor.transaction do
          perform_conflict_resolution(executor, deletion: true)
          perform_user_replacement(executor)
        end
      end
      nil
    end

    def delete_source_users(perform: false)
      # Check that no traces of the source users remain.
      check_personal_projects_clear
      puts 'Checking for traces of source users in database...'
      ColumnClassifier.new.scan.check_empty
      check_namespace_owner_id
      return unless perform

      puts 'Deleting source users...'
      duplicated_users.each(&:destroy!)
      nil
    end
  end
end

"
Dir.chdir('<path to codebase>')
load 'gitlab_user_merge.rb'
tool = GitlabUserMerge::Tool.new
"

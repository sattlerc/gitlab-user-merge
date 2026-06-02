# frozen_string_literal: true

module GitlabUserMerge
  # Path constants.
  # PATH_JSON_ANALYSIS = '/home/sattler/mnt/analysis.json'
  # DIR_JSON_ANALYSIS = '/home/sattler/mnt/analysis'
  # DIR_JSON = '/home/sattler/mnt/json'
  # DIR_TEXT = '/home/sattler/mnt/text'
end

require_relative 'lib/general'
require_relative 'lib/deserialization'
require_relative 'lib/json'
require_relative 'lib/sql'
require_relative 'lib/version'
require_relative 'lib/models'

# Reads from PATH_USER_MAPPING.
require_relative 'lib/user_mapping'

# Writes to and reads from PATH_COLUMN_CLASSIFICATION.
require_relative 'lib/column_classification'

require_relative 'lib/chronologicity'
require_relative 'lib/resolution'
require_relative 'lib/uniqueness_check'
require_relative 'lib/replacement'
require_relative 'lib/personal_projects'

# Unused in production.
# require_relative 'lib/membership'

module C
  # include GitlabUserMerge

  # M = GitlabUserMerge::Membership.new
  # M.test

  # C = GitlabUserMerge::ColumnClassifier.new
  # File.open('/home/sattler/mnt/column-classification-report.txt', 'w') do |file|
  #   C.scan_and_write(file: file)
  # end

  # chrono = GitlabUserMerge::ChronologicityCheck.new
  # File.open('/home/sattler/mnt/chronicity.txt', 'w') do |file|
  #   chrono.check(file: file, strict: false)
  # end

  # U = GitlabUserMerge::UniquenessCheck.new
  # U.check_for_unresolved_conflicts
  # U.print_resolution_queries

  # P = GitlabUserMerge::PersonalProjects.new
  # P.report_namespace_projects
  # P.check_namespace_projects
  # P.transfer_personal_projects

  # R = GitlabUserMerge::Replacement.new
  # R.test

  # File.open('/home/sattler/mnt/column_conflicts_by_user_id.txt', 'w') do |file|
  #   U.print_column_conflicts_by_version_user_id(file: file, resolution: true)
  # end
  # File.open('/home/sattler/mnt/column_conflicts_by_table_and_column.txt', 'w') do |file|
  #   U.print_column_conflicts_by_table_and_column(file: file, resolution: true)
  # end
  #U.column_conflicts_by_table
  #U.print_column_conflicts_by_table_and_column
  #U.print_column_conflicts_by_version_user_id(resolution: true)
  #foreign_keys_for_table
  #puts unique.foreign_keys_for_model(UserDetail)
  #checker.print_relevant_unique_index
  #checker.print_conflict_columns
  #checker.print_resolve_conflicts(resolution: false)
end

# load "/home/sattler/mnt/ruby/chalmers_gitlab_fixing.rb"

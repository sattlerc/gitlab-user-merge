# frozen_string_literal: true

module ChalmersGitlabFixing
  # Path constants.
  # PATH_JSON_ANALYSIS = '/home/sattler/mnt/analysis.json'
  # DIR_JSON_ANALYSIS = '/home/sattler/mnt/analysis'
  # DIR_JSON = '/home/sattler/mnt/json'
  # DIR_TEXT = '/home/sattler/mnt/text'
end

# change to require_relative
$LOAD_PATH.unshift File.dirname(__FILE__)
load 'chalmers_gitlab_fixing/general.rb'
load 'chalmers_gitlab_fixing/deserialization.rb'
load 'chalmers_gitlab_fixing/json.rb'
load 'chalmers_gitlab_fixing/sql.rb'
load 'chalmers_gitlab_fixing/models.rb'
load 'chalmers_gitlab_fixing/version.rb'
load 'chalmers_gitlab_fixing/user_mapping.rb'
load 'chalmers_gitlab_fixing/personal_projects.rb'
load 'chalmers_gitlab_fixing/column_classification.rb'
load 'chalmers_gitlab_fixing/chronologicity.rb'
load 'chalmers_gitlab_fixing/resolution.rb'
load 'chalmers_gitlab_fixing/uniqueness_check.rb'
load 'chalmers_gitlab_fixing/membership.rb'

module C
  # include ChalmersGitlabFixing

  M = ChalmersGitlabFixing::Membership.new
  # M.test

  # C = ChalmersGitlabFixing::ColumnClassifier.new
  # File.open('/home/sattler/mnt/column-classification-report.txt', 'w') do |file|
  #   C.scan_and_write(file: file)
  # end

  # chrono = ChalmersGitlabFixing::ChronologicityCheck.new
  # File.open('/home/sattler/mnt/chronicity.txt', 'w') do |file|
  #   chrono.check(file: file, strict: false)
  # end

  U = ChalmersGitlabFixing::UniquenessCheck.new
  # U.print_resolution_queries

  P = ChalmersGitlabFixing::PersonalProjects.new
  # P.report_namespace_projects
  # P.check_namespace_projects
  P.transfer_personal_projects

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

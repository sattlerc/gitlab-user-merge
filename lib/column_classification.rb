# frozen_string_literal: true

module GitlabUserMerge
  # Writes and reads "column-classification.json" in current directory.
  # Can be overriden using environment variable PATH_COLUMN_CLASSIFICATION.
  PATH_COLUMN_CLASSIFICATION = ENV.fetch('PATH_COLUMN_CLASSIFICATION', 'column-classification.json')

  # SQL = GitlabUserMerge::SQL

  # Classification of columns.
  # Possible match results:
  # * positive/negative: we confirmed that this column does / does not match,
  # * unrecognized: we are unsure.
  class ColumnMatches
    include ActiveModel::Serialization
    include Deserialization

    def initialize
      @positive = Set.new
      @negative = Set.new
      @unrecognized = Set.new
      @ignored = Set.new
    end

    attr_reader :positive, :negative, :unrecognized, :ignored

    def hash
      {
        true => @positive,
        false => @negative,
        :unrecognized => @unrecognized,
        :ignored => @ignored
      }
    end

    def report_table_columns(name, table_columns, file: $stdout)
      file.puts "#{name}: #{table_columns.length}"
      return if table_columns.empty?

      table_columns.each do |table, column|
        file.puts "- #{table}.#{column}"
      end
      file.puts
    end

    def report(file: $stdout)
      report_table_columns('positive', @positive, file: file)
      report_table_columns('negative', @negative, file: file)
      report_table_columns('unrecognized', @unrecognized, file: file)
    end
  end

  # Classification of different kinds of columns:
  # * :array:
  #   Array column.
  #   Its type is array of 'integer' or 'bigint'.
  #   For the other kinds, the type is 'integer' or 'bigint'.
  # * :polymorphic:
  #   Foreign key to several different tables at once.
  #   Of the form <stem>_id.
  #   Comes with a column <stem>_type of type 'text' or 'varying char'.
  #   This indicates the parent model.
  # * :ordinary:
  #   Not of the above two kinds.
  class ColumnClassification
    include ActiveModel::Serialization
    include Deserialization

    def initialize(search_user_ids = nil)
      search_user_ids = [].to_set if search_user_ids.nil?
      @search_user_ids = search_user_ids

      @array = ColumnMatches.new
      @polymorphic = ColumnMatches.new
      @ordinary = ColumnMatches.new
    end

    attr_reader :ordinary, :polymorphic, :array

    def hash
      {
        array: @array,
        polymorphic: @polymorphic,
        ordinary: @ordinary
      }
    end

    def report(file: stdout)
      file.puts '## Column classification report'
      file.puts
      hash.each do |kind, matches|
        file.puts "### #{kind.to_s.capitalize} columns"
        file.puts
        matches.report(file: file)
        file.puts
      end
    end
  end

  # Loading and caching a column classification.
  module WithColumnClassification
    include UserMapping

    def column_classification
      @column_classification ||= ColumnClassification.new.deserialize(JSON.read(PATH_COLUMN_CLASSIFICATION))
    end

    def relevant_columns
      column_classification.hash.values.flat_map { |cm| cm.positive.to_a }.to_set
    end
  end

  # Creates column classification.
  class ColumnClassifier
    include SQLExecution
    include Models
    include UserMapping

    def check_single_database
      database_main = connection.current_database
      database_ci = Ci::ApplicationRecord.connection.current_database
      raise "Main and Ci databases differ: #{database_main} vs. #{database_ci}" unless database_main == database_ci
    end

    def search(table, column, column_type: nil)
      table_column = SQL.table_column(TABLE_USER_MAPPING, VERSION_COLUMN_USER_MAPPING[:source])
      query = SQL.spacing do |e|
        e << SQL::SELECT
        e << table_column
        e << SQL.from([table, TABLE_USER_MAPPING])
        e << SQL.where do |e1|
          e1 << SQL.equals(SQL.table_column(table, column.name), table_column)
          e1 << SQL.equals(SQL.table_column(table, column_type.name), SQL.string('User')) unless column_type.nil?
        end
        e << SQL.limit
      end
      !connection.select_values(query).empty?
    end

    # Array columns

    def column_array?(table, column)
      actual_type = column.sql_type_metadata.sql_type
      return false if %w[bigint integer].include?(actual_type)
      return true if %w[bigint[] integer[]].include?(actual_type)

      raise "Unexpected type of #{table}.#{column.name}: #{type}" unless type == 'bigint'
    end

    # Override for array columns referencing users.
    TABLE_COLUMN_ARRAY_INCLUDE = [
      %w[issue_user_mentions mentioned_users_ids],
      %w[merge_request_user_mentions mentioned_users_ids]
    ].to_set

    def scan_column_array(table, column)
      # Inspect Rails relations.
      query = SQL.spacing do |e|
        e << SQL::SELECT
        e << SQL::DISTINCT
        e << SQL.identifier(column.name)
        e << SQL.from(table)
      end
      values = connection
               .select_values(query)
               .map { |xs| SQL.decode_array(xs) }
               .compact
               .flatten
               .to_set
      return false if values.empty?
      return false unless values.max < user_id_upper_bound_relaxed
      return false if values.disjoint?(duplicated_user_ids)

      table_column = [table, column.name]
      return true if TABLE_COLUMN_ARRAY_INCLUDE.include?(table_column)

      :unrecognized
    end

    # Polymorphic columns

    def column_polymorphic?(table, column)
      # Two different tests for polymorphism:
      # a) via Rails reflection,
      # b) testing for a corresponding type column,
      column_type = polymorphic_type_column(table, column)
      return true unless column_type.nil?

      models_by_table[table].each do |model|
        foreign_keys_for_model(model).each do |_foreign_keys|
          if foreign_keys_for_model(model)[column.name] == :polymorphic
            raise "#{table}.#{column.name}: non-standard polymorphic column"
          end
        end
      end
      false
    end

    def scan_column_polymorphic(table, column)
      column_type = polymorphic_type_column(table, column)

      # Redundant with next check.
      query = SQL.spacing do |e|
        e << SQL::SELECT
        e << SQL::DISTINCT
        e << SQL.identifier(column_type.name)
        e << SQL.from(table)
      end
      values = connection.select_values(query).compact
      return false unless values.include?('User')

      # If the column does not contain any of the search keys of the User model, it does not match.
      search(table, column, column_type: column_type)
    end

    # Ordinary columns

    def user_id_upper_bound
      @user_id_upper_bound ||=
        begin
          query = SQL.spacing do |e|
            e << SQL::SELECT
            e << SQL.upper_bound(SQL.identifier('id'))
            e << SQL.from('users')
          end
          connection.select_value(query)
        end
    end

    def user_id_upper_bound_relaxed
      user_id_upper_bound + 10
    end

    TABLE_COLUMN_INCLUDE = [
      %w[group_type_ci_runners creator_id],
      %w[groups_visits user_id],
      %w[oauth_access_grants resource_owner_id],
      %w[project_authorizations_for_migration user_id],
      %w[projects_visits user_id],
      %w[user_audit_events user_id]
    ].to_set

    def scan_column_ordinary(table, column)
      # If the column does not contain any of the search keys, it does not match.
      return false unless search(table, column)

      # Inspect database foreign keys.
      foreign_key = foreign_key(table, column)
      return foreign_keys == 'users' unless foreign_key.nil?

      # Inspect Rails relations.
      types = models_by_table[table].map do |model|
        parent = foreign_keys_for_model(model)[column.name]
        if parent.nil?
          :unknown
        elsif parent == 'users'
          :user
        elsif parent == :polymorphic
          raise "assertion failed: polymorpic column #{table}.#{column.name}"
        else
          :other
        end
      end.to_set
      # puts "#{table}.#{column.name}: #{types}"
      return false if types == [:other].to_set
      return true if types == [:user].to_set

      # I checked that all columns with a default value do not refer to user ids.
      models_by_table[table].each do |model|
        model_column = model.columns_hash[column.name]
        next if model_column.nil?
        return false unless model_column.default.nil?
      end

      # If the (non-polymorphic) column contains values outside the range of user ids, it does not contain user ids.
      query = SQL.spacing do |e|
        e << SQL::SELECT
        e << SQL.identifier(column.name)
        e << SQL.from(table)
        e << SQL.where(SQL.not_(SQL.less(SQL.identifier(column.name), SQL.integer(user_id_upper_bound_relaxed))))
        e << SQL.limit
      end
      return false unless connection.select_values(query).empty?

      # return false if COLUMN_EXCLUDE.include?(column.name)
      return true if TABLE_COLUMN_INCLUDE.include?([table, column.name])

      # return false if column.name == primary_key || (primary_key.is_a?(Array) && primary_key.include?(column.name))
      return table == 'users' if column.name == 'id' && column.name == connection.primary_key(table)

      :unrecognized
    end

    def scan_column(table, column, cc)
      return false unless %w[bigint integer].include?(column.sql_type)
      return false if column.name.ends_with?('_convert_to_bigint')

      if column_polymorphic?(table, column)
        type = scan_column_polymorphic(table, column)
        matches = cc.polymorphic
      elsif column_array?(table, column)
        type = scan_column_array(table, column)
        matches = cc.array
      else
        type = scan_column_ordinary(table, column)
        matches = cc.ordinary
      end
      matches.hash[type].add([table, column.name])
    end

    def scan
      cc = ColumnClassification.new(duplicated_user_ids)
      with_table_user_mapping do
        inhabited_tables.each do |table|
          connection.columns(table).each do |column|
            scan_column(table, column, cc)
          end
        end
      end
      cc
    end

    def scan_and_write(path_out: PATH_COLUMN_CLASSIFICATION, file: $stdout)
      cc = scan
      cc.report(file: file)
      JSON.write(path_out, ::JSON.parse(cc.to_json))
      puts "Column classification written to #{PATH_COLUMN_CLASSIFICATION}."
    end
  end
end

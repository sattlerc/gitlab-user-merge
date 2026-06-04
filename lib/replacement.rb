# frozen_string_literal: true

module GitlabUserMerge
  module Replacement
    include SQLExecution
    include Models
    include UserMapping
    include WithColumnClassification

    def perform_user_replacement_in_non_array_column(table, column, executor, polymorphic: false, &side_condition)
      query = SQL.spacing do |e|
        e << SQL::UPDATE
        e << SQL.identifier(table)
        e << SQL.set([[column, SQL.table_column(TABLE_USER_MAPPING, VERSION_COLUMN_USER_MAPPING[:target])]])
        e << SQL.from([TABLE_USER_MAPPING])
        e << SQL.where do |e1|
          e1 << SQL.equals(
            SQL.identifier(column),
            SQL.table_column(TABLE_USER_MAPPING, VERSION_COLUMN_USER_MAPPING[:source])
          )
          if polymorphic
            e1 << SQL.equals(SQL.identifier(polymorphic_type_column(table, column).name), SQL.value('User'))
          end
          side_condition.call(e1) unless side_condition.nil?
        end
      end
      executor.execute(query)
    end

    def perform_user_replacement_in_array_cell(table, column, executor, keys, version_user_id)
      replace = SQL.function(
        'array_replace',
        SQL.identifier(column),
        SQL.value(version_user_id[:source]),
        SQL.value(version_user_id[:target])
      )
      query = SQL.spacing do |e|
        e << SQL::UPDATE
        e << SQL.identifier(table)
        e << SQL.set([[column, replace]])
        e << SQL.where do |e1|
          keys.entries.each do |key, value|
            e1 << SQL.equals(SQL.identifier(key), SQL.value(value))
          end
        end
      end
      executor.execute(query)
    end

    def perform_user_replacement_in_array_column(table, column, executor)
      primary_keys = primary_keys(table)
      query_rows = SQL.spacing do |e|
        e << SQL::SELECT
        e << SQL.list([*primary_keys.map { |c| SQL.identifier(c) }, VERSION_COLUMN_USER_MAPPING[:source]])
        e << SQL.from([table, TABLE_USER_MAPPING])
        e << SQL.where do |e1|
          e1 << SQL.equals(
            SQL.table_column(TABLE_USER_MAPPING, VERSION_COLUMN_USER_MAPPING[:source]),
            SQL.function('ANY', [SQL.identifier(column)])
          )
        end
      end
      connection.select_all(query_rows).each do |keys|
        source_user_id = keys.delete(VERSION_COLUMN_USER_MAPPING[:source])
        target_user_id = user_mapping[source_user_id]
        version_user_id = Version.of_pair([source_user_id, target_user_id])
        perform_user_replacement_in_array_cell(table, column, executor, keys, version_user_id)
      end
    end

    def perform_user_replacement_in_array_columns(executor)
      column_classification.array.positive.each do |table, column|
        perform_user_replacement_in_array_column(table, column, executor)
      end
    end

    def perform_user_replacement_in_ordinary_columns(executor)
      column_classification.ordinary.positive.each do |table, column|
        next if table == 'users' && column == 'id'

        if table == 'namespaces' && column == 'owner_id'
          perform_user_replacement_in_non_array_column(table, column, executor) do |e|
            e << sql_not_user_namespace(SQL.identifier('type'))
          end
        else
          perform_user_replacement_in_non_array_column(table, column, executor)
        end
      end
    end

    def perform_user_replacement_in_polymorphic_columns(executor)
      column_classification.polymorphic.positive.each do |table, column|
        perform_user_replacement_in_non_array_column(table, column, executor, polymorphic: true)
      end
    end

    def perform_user_replacement(executor)
      with_table_user_mapping do
        perform_user_replacement_in_ordinary_columns(executor)
        perform_user_replacement_in_polymorphic_columns(executor)
        perform_user_replacement_in_array_columns(executor)
      end
    end
  end
end

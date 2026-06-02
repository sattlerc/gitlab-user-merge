# frozen_string_literal: true

module ChalmersGitlabFixing
  module Replacement
    include SQLExecution
    include Models
    include UserMapping
    include WithColumnClassification

    def replace_user_in_non_array_column_sql_query(table, column, polymorphic: false, &side_condition)
      SQL.spacing do |e|
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
            e1 << SQL.equals(SQL.identifier(ColumnClassificationHelper.polymorphic_type_column(table, column),
                                            SQL.value('User')))
          end
          side_condition.call(e1) unless side_condition.nil?
        end
      end
    end

    def replace_user_find_array_rows_sql_query(table, column)
      primary_keys = primary_keys(table)
      SQL.spacing do |e|
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
    end

    def replace_user_in_array_cell_sql_query(table, column, keys, version_user_id)
      replace = SQL.function(
        'array_replace',
        SQL.identifier(column),
        SQL.value(version_user_id[:source]),
        SQL.value(version_user_id[:target])
      )
      SQL.spacing do |e|
        e << SQL::UPDATE
        e << SQL.identifier(table)
        e << SQL.set([[column, replace]])
        e << SQL.where do |e1|
          keys.entries.each do |key, value|
            e1 << SQL.equals(SQL.identifier(key), SQL.value(value))
          end
        end
      end
    end

    def replace_user_in_non_array_column(table, column, polymorphic: false)
      query_replace = replace_user_in_non_array_column_sql_query(table, column, polymorphic: polymorphic)
      connection.execute(query_replace)
    end

    def replace_user_in_array_column(table, column)
      query_rows = replace_user_find_array_rows_sql_query(table, column)
      connection.select_all(query_rows).each do |h|
        source_user_id = h.delete(VERSION_COLUMN_USER_MAPPING[:source])
        target_user_id = user_mapping[source_user_id]
        version_user_id = Version.of_pair([source_user_id, target_user_id])
        query_replace = replace_user_sql_queries_for_array_cell(table, column, h, version_user_id)
        connection.execute(query_replace)
      end
    end
  end
end

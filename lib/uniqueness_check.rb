# frozen_string_literal: true

# Scans for obstacles to merging of users.
module GitlabUserMerge
  module UniquenessCheck
    include SQLExecution
    include UserMapping
    include Models
    include WithColumnClassification
    include Chronologicity
    include WithResolutions

    # These do not mention user ids.
    TABLE_INDEX_COLUMNS_IGNORE = [
      ['achievements', 'namespace_id, lower(name)'],
      ['activity_pub_releases_subscriptions', 'project_id, lower(subscriber_inbox_url)'],
      ['activity_pub_releases_subscriptions', 'project_id, lower(subscriber_url)'],
      ['automation_rules', 'namespace_id, lower(name)'],
      ['custom_field_select_options', 'custom_field_id, lower(value)'],
      ['custom_fields', 'namespace_id, lower(name)'],
      ['customer_relations_contacts', 'group_id, lower(email), id'],
      ['customer_relations_organizations', 'group_id, lower(name), id'],
      ['group_scim_identities', 'lower(extern_uid), group_id'],
      ['incident_management_timeline_event_tags', 'project_id, lower(name)'],
      ['issue_email_participants', 'issue_id, lower(email)'],
      ['organizations', 'lower(path)'],
      ['redirect_routes', 'lower((path)::text) varchar_pattern_ops'],
      ['scim_identities', 'lower((extern_uid)::text), group_id'],
      ['security_scan_profiles', 'namespace_id, scan_type, lower(name)'],
      ['timelog_categories', 'namespace_id, lower(name)'],
      ['work_item_custom_statuses', 'namespace_id, TRIM(BOTH FROM lower(name))'],
      ['work_item_custom_types', 'namespace_id, lower(name)'],
      ['work_item_custom_types', 'organization_id, lower(name)'],
      ['work_item_types', 'TRIM(BOTH FROM lower(name))'],
      ['work_item_widget_definitions', 'work_item_type_id, TRIM(BOTH FROM lower(name))']
    ].to_set

    # def query_mapping_in_table(table, column)
    #   SQL.spacing do |e|
    #     e << SQL::SELECT
    #     e << SQL.listing do |e1|
    #       Version::VERSIONS.each do |v|
    #         e1 << SQL.as(Version.sql_column(v, user_column), SQL::ANY)
    #       end
    #     end
    #     e << SQL.from([*Version::VERSIONS.map { |v| [table, Version.sql(v)] }, TABLE_USER_MAPPING])
    #     e << SQL.where do |e1|
    #       Version::VERSIONS.each do |v|
    #         e1 << SQL.equals(
    #           Version.sql_column(v, column),
    #           SQL.table_column(TABLE_USER_MAPPING, VERSION_COLUMN_USER_MAPPING[v])
    #         )
    #       end
    #     end
    #   end
    # end

    def process_column_array(table, columns, e)
      table_columns = columns.map { |column| [table, column] }.to_set
      e << columns.to_set unless table_columns.disjoint?(relevant_columns)
    end

    def table_relevant_unique_indexes(table, e)
      connection.indexes(table).each do |index|
        next unless index.unique

        if index.columns.class == String
          next if TABLE_INDEX_COLUMNS_IGNORE.include?([table, index.columns])

          raise "unknown columns of index of table #{table}: #{index.columns}"
        end

        process_column_array(table, index.columns, e)
      end

      columns = primary_keys(table)
      process_column_array(table, columns, e) unless columns.nil?
    end

    def relevant_unique_indexes_for_table_uncached(table)
      indexes = Enumerator.new do |e|
        table_relevant_unique_indexes(table, e)
      end.to_set

      # Skip an index if there is a coarser index.
      indexes.reject do |index|
        indexes.any? { |index_coarser| index_coarser < index }
      end.to_set
    end

    def relevant_unique_indexes_for_table(table)
      @relevant_unique_indexes_for_table ||= {}
      @relevant_unique_indexes_for_table[table] ||= relevant_unique_indexes_for_table_uncached(table)
      @relevant_unique_indexes_for_table[table]
    end

    def user_index(table, index)
      user_columns = index.select { |column| relevant_columns.include?([table, column]) }.to_set
      unless user_columns.length == 1
        raise "Table #{table} has relevant unique index #{index.to_a} with multiple user id columns: #{user_columns}."
      end

      user_column = user_columns.to_a[0]
      other_columns = index - [user_column]
      [user_column, other_columns]
    end

    def print_relevant_unique_indexes(file: $stdout)
      inhabited_tables.each do |table|
        indexes = relevant_unique_indexes_for_table(table)
        next if indexes.empty?

        file.puts "#{table}:"
        indexes.each do |index|
          user_column, other_columns = user_index(table, index)
          file.puts "* #{user_column} with #{other_columns.to_a}"
        end
      end
    end

    # We observe that there is at most one relevant unique index per table.
    # This hash records it.
    def relevant_unique_index_by_table_uncached
      inhabited_tables
        .map { |table| [table, relevant_unique_indexes_for_table(table).to_a] }
        .reject { |_table, indexes| indexes.empty? }
        .to_h do |table, indexes|
        raise "Table #{table} has several relevant unique indexes: #{indexes}" unless indexes.length == 1

        [table, indexes[0]]
      end
    end

    def relevant_unique_index_by_table
      @relevant_unique_index_by_table ||= relevant_unique_index_by_table_uncached
    end

    def print_relevant_unique_index(file: $stdout)
      relevant_unique_index_by_table.entries.each do |table, index|
        user_column, other_columns = user_index(table, index)
        file.puts "#{table}: #{user_column} with #{other_columns.to_a}"
      end
    end

    def relevant_user_column_for_table(table)
      index = relevant_unique_index_by_table[table]
      user_column, _other_columns = user_index(table, index)
      user_column
    end

    def table_columns_missing_cascading_deletion_uncached
      Enumerator.new do |e|
        relevant_unique_index_by_table.keys.each do |table|
          user_column = relevant_user_column_for_table(table)
          foreign_key = General.from_singleton(
            foreign_keys_by_column_for_table(table).fetch(user_column, []),
            allow_empty: true
          )
          e << [table, user_column] unless !foreign_key.nil? && foreign_key.options[:on_delete] == :cascade
        end
      end.to_set
    end

    def table_columns_missing_cascading_deletion
      @table_columns_missing_cascading_deletion ||= table_columns_missing_cascading_deletion_uncached
    end

    def print_table_columns_missing_cascading_deletion(file: $stdout)
      file.puts '## Table columns missing cascading deletion'
      file.puts
      if table_columns_missing_cascading_deletion.empty?
        file.puts 'None'
      else
        table_columns_missing_cascading_deletion.each do |table, column|
          file.puts "#{table}.#{column}"
        end
      end
      file.puts
    end

    def query_conflict(table, user_column, other_columns)
      SQL.spacing do |e|
        e << SQL::SELECT
        e << SQL.listing do |e1|
          Version::VERSIONS.each do |v|
            e1 << SQL.as(Version.sql_column(v, user_column), Version.sql_user_id(v))
          end
          other_columns.each do |column|
            e1 << SQL.as(Version.sql_column(:source, column), column)
          end
        end
        e << SQL.from([*Version::VERSIONS.map { |v| [table, Version.sql(v)] }, TABLE_USER_MAPPING])
        e << SQL.where do |e1|
          Version::VERSIONS.each do |v|
            e1 << SQL.equals(
              Version.sql_column(v, user_column),
              SQL.table_column(TABLE_USER_MAPPING, VERSION_COLUMN_USER_MAPPING[v])
            )
          end
          other_columns.each do |column|
            e1 << SQL.equals(*Version::VERSIONS.map { |v| Version.sql_column(v, column) })
          end
        end
      end
    end

    # Returns hash sending {source: key, target: key} to {column => {source: row[column], target: row[column]}}.
    def column_conflicts_for_index(table, index)
      user_column, other_columns = user_index(table, index)

      connection.select_all(query_conflict(table, user_column, other_columns)).map do |r|
        version_user_id = Version::VERSIONS.to_h { |v| [v, r.delete(Version.sql_user_id(v))] }
        version_keys = Version::VERSIONS.to_h { |v| [v, { user_column => version_user_id[v] }.merge(r)] }
        version_row = version_keys.transform_values { |key| select_unique_by_keys(table, key) }

        key = General.from_singleton(version_row.values.map(&:keys).to_set)
        values = key
                 .reject { |column| column == user_column }
                 .reject { |column| !resolution(table, column).nil? && resolution(table, column).ignore? }
                 .reject { |column| General.equal_strictly(*version_row.values.map { |row| row[column] }) }
                 .index_with { |column| version_row.transform_values { |row| row[column] } }
        [version_keys, values]
      end.compact.to_h
    end

    def column_conflicts_by_table_uncached
      with_table_user_mapping do
        relevant_unique_index_by_table.entries.map do |table, index|
          [table, column_conflicts_for_index(table, index)]
        end.reject do |_table, conflicts|
          conflicts.empty?
        end.to_h
      end
    end

    def column_conflicts_by_table
      @column_conflicts_by_table ||= column_conflicts_by_table_uncached
    end

    def conflict_columns(table)
      column_conflicts_by_table[table].values.flat_map { |values| values.keys.to_a }.to_set
    end

    def print_conflict_columns(file: $stdout)
      column_conflicts_by_table.keys.each do |table|
        file.puts "#{table}: #{conflict_columns(table).to_a.join(', ')}"
        # conflict_columns(table).each do |column|
        #   file.puts "%w[#{table} #{column}]"
        # end
      end
    end

    def format_version_keys(version_keys)
      SQL.format_symbol_hash(version_keys) do |value|
        SQL.format_symbol_hash(value.transform_keys(&:intern))
      end
    end

    def column_conflicts_by_table_and_column_uncached
      column_conflicts_by_table.transform_values do |conflicts|
        separated = conflicts.entries.flat_map do |version_keys, values|
          values.entries.map do |column, version_value|
            [column, [version_keys, version_value]]
          end
        end
        General.group(separated).transform_values do |for_column|
          General.group(for_column).transform_values do |for_version_keys|
            General.from_singleton(for_version_keys)
          end
        end
      end
    end

    # Content: table => column => version_keys => version_value
    def column_conflicts_by_table_and_column
      @column_conflicts_by_table_and_column ||= column_conflicts_by_table_and_column_uncached
    end

    def print_column_conflicts_by_table_and_column(file: $stdout, skip_resolved: false, include_resolution: false)
      file.puts "## #{skip_resolved ? 'Unresolved conflicts' : 'Conflicts'} by table column"
      file.puts
      if !skip_resolved && resolution
        file.puts 'Resolution decisions are highlighted.'
        file.puts
      end
      column_conflicts_by_table_and_column.entries.each do |table, by_column|
        by_column.entries.each do |column, by_keys|
          next if skip_resolved && !resolution(table, column).nil?

          c = columns_for_table(table)[column]
          file.puts "### Table column #{table}.#{column}"
          file.puts
          file.puts "SQL type #{c.sql_type}, default #{SQL.format_value(c.default)}"
          file.puts
          file.puts "Resolution: #{resolution(table, column)}"
          file.puts
          by_keys.entries.each do |version_keys, version_value|
            formatted_keys = format_version_keys(version_keys)
            formatted_value = format_version_value(table, column, version_keys, version_value,
                                                   resolution: include_resolution)
            file.puts "* #{formatted_keys}: #{formatted_value}"
          end
          file.puts
        end
      end
    end

    def column_conflicts_by_version_user_id_uncached
      flat = column_conflicts_by_table.entries.flat_map do |table, conflicts|
        user_column = relevant_user_column_for_table(table)
        conflicts
          # Maybe allow it?
          # Makes printing uglier, but needed for proper deletion.
          .reject { |_, values| values.empty? }
          .map do |version_keys, values|
          version_user_id = version_keys.transform_values { |keys| keys.fetch(user_column) }
          [version_user_id, [table, [version_keys, values]]]
        end
      end
      General.group(flat).transform_values do |for_table|
        General.group(for_table)
      end
    end

    # Content: version_user_id => table => [version_keys, column => version_value]
    def column_conflicts_by_version_user_id
      @column_conflicts_by_version_user_id ||= column_conflicts_by_version_user_id_uncached
    end

    def print_column_conflicts_by_version_user_id(file: $stdout, skip_resolved: false, include_resolution: false)
      file.puts "## #{skip_resolved ? 'Unresolved conflicts' : 'Conflicts'} by user mapping}"
      file.puts
      if !skip_resolved && resolution
        file.puts 'Resolution decisions are highlighted.'
        file.puts
      end
      column_conflicts_by_version_user_id.entries.each do |version_user_id, by_table|
        file.puts "### User mapping #{format_version_user_id(version_user_id)}"
        file.puts
        by_table.entries.each do |table, for_table|
          file.puts "#### Table #{table}"
          file.puts
          for_table.entries.each do |version_keys, values|
            next if values.empty?

            formatted_keys = format_version_keys(version_keys)
            file.puts "Keys #{formatted_keys}:"
            values.entries.each do |column, version_value|
              next if skip_resolved && !resolution(table, column).nil?

              formatted_value = format_version_value(table, column, version_keys, version_value,
                                                     resolution: include_resolution)
              file.puts "* #{column}: #{formatted_value}"
            end
            file.puts
          end
        end
      end
    end

    def unresolved_conflicts
      @unresolved_conflicts ||= column_conflicts_by_table_and_column.entries.flat_map do |table, by_column|
        by_column.keys.select { |column| resolution(table, column).nil? }.map do |column|
          [table, column]
        end
      end.to_set
    end

    def check_for_unresolved_conflicts(file: $stdout)
      file.puts 'Checking for unresolved conflicts...'
      return if unresolved_conflicts.empty?

      file.puts
      print_column_conflicts_by_table_and_column(file: file, skip_resolved: true)
      raise "Unresolved conflicts: #{unresolved_conflicts}"
    end

    def resolution_sql_queries_for_table(table, deletion: false, &block)
      column_conflicts_by_table[table].entries.each do |version_keys, values|
        resolution_sql_queries_for_conflict(table, version_keys, values, deletion: deletion, &block)
      end
    end

    # If activated, deletes from users table last to handle cascading deletion.
    #
    # Note:
    # Users should rather be deleted at application logic level (User.find(id).destroy!).
    # The database logic misses some cascading deletions.
    def resolution_sql_queries(delete_user: false, deletion: false, &block)
      table_users, table_non_users = column_conflicts_by_table.keys.partition { |table| table == 'users' }
      table_non_users.each do |table|
        resolution_sql_queries_for_table(table, deletion: deletion, &block)
      end
      table_users.each do |table|
        resolution_sql_queries_for_table(table, deletion: deletion && delete_user, &block)
      end
    end

    def print_resolution_queries(deletion: false, file: $stdout)
      resolution_sql_queries(deletion: deletion) do |query|
        file.puts query
      end
    end
  end
end

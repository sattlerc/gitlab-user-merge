module GitlabUserMerge
  DIR_JSON = ENV.fetch('DIR_JSON', 'json')
  DIR_TEXT = ENV.fetch('DIR_TEXT', 'text')

  class Text
    include SQLExecution
    include UserMapping

    def search_in_str(s)
      duplicated_user_ids.each do |id|
        return true if s.include?(id.to_s)
      end
      false
    end

    def sql_query_group_non_null(table, column)
      SQL.spacing do |e|
        e << SQL::SELECT
        e << SQL.listing do |e1|
          e1 << row_id(table, column)
          e1 << SQL.identifier(column)
        end
        e << SQL.from(table)
        e << SQL.where(SQL.space([SQL.identifier(column), SQL::IS, SQL::NOT, SQL::NULL]))
        e << SQL.group_by(column)
      end
    end

    def json_filter_integer
      @json_filter_integers ||= user_mapping.keys.to_set
    end

    def json_filter_string
      @json_filter_strings ||= duplicated_user_usernames
    end

    TEXT_COLUMNS_EXCLUDE = [
      %w[description_versions description],
      %w[emails detumbled_email],
      %w[emails email],
      %w[identities extern_uid],
      %w[issues description],
      %w[issues description_html],
      %w[merge_request_diff_commits message],      
      %w[merge_request_diff_files diff],
      %w[merge_request_diff_files_99208b8fac diff],
      %w[merge_requests description],
      %w[merge_requests description_html],
      %w[merge_requests source_branch],
      %w[merge_requests title_html],
      %w[namespaces path],
      %w[notes note],
      %w[notes note_html],
      %w[push_event_payloads commit_title],
      %w[push_event_payloads ref],
      %w[redirect_routes path],
      %w[routes path],
      %w[users email],
      %w[users username],
      %w[work_item_descriptions description],
      %w[work_item_descriptions description_html],
    ].to_set

    def check_text_columns(file: $stdout)
      file.puts 'Scanning text columns for:'
      file.puts '* integers matching duplicated user ids,'
      file.puts '* strings containing duplicated usernames.'
      file.puts
      file.puts "Matching text values will be stored in #{DIR_TEXT}..."
      file.puts

      inhabited_tables.each do |table|
        connection.columns(table).each do |column|
          table_column = [table, column.name]
          next unless SQL.type_text?(column.sql_type)
          next if TEXT_COLUMNS_EXCLUDE.include?(table_column)

          puts "Scanning #{table}.#{column.name}..."

          matching_ids = Set.new
          matching_usernames = Set.new

          connection.select_rows(sql_query_group_non_null(table, column.name)).each do |id, value|
            begin
              json = ::JSON.parse! value
            rescue ::JSON::ParserError
              json = nil
            end

            if !json.nil?
              search = JSONContextSearch.new(
                json,
                filter_integer: json_filter_integer,
                filter_string: json_filter_string,
              )
              next if search.integers.empty? && search.strings.empty?

              search.report(file: file)
              matching_ids |= search.integers.keys
              matching_usernames |= search.strings.keys

              suffix = "-#{search.integers.keys.join(',')}-#{search.strings.keys.join(',')}"
              path = "#{DIR_JSON}/#{table}.#{column.name}/#{id}#{suffix}"
              FileUtils.mkdir_p(File.dirname(path))
              JSON.write(path, json)
            else
              strings = scan_for_duplicated_user_usernames(value)
              next if strings.empty?

              file.puts "* #{strings}: #{value}"
              matching_usernames |= strings

              suffix = "-#{strings.join(',')}"
              path = "#{DIR_TEXT}/#{table}.#{column.name}/#{id}#{suffix}"
              FileUtils.mkdir_p(File.dirname(path))
              File.open(path, 'w') do |file|
                file.puts(value)
              end
            end
          end
          next if matching_ids.empty? && matching_usernames.empty?

          file.puts
        end
      end
    end

    def check_json_columns(file: $stdout)
      file.puts 'Scanning JSON columns for:'
      file.puts '* integers matching duplicated user ids,'
      file.puts '* strings containing duplicated usernames.'
      file.puts
      file.puts "Matching JSON values will be stored in #{DIR_JSON}..."
      file.puts

      inhabited_tables.each do |table|
        connection.columns(table).each do |column|
          next unless column.sql_type == 'jsonb'

          file.puts "Scanning #{table}.#{column.name}..."

          matching_ids = Set.new
          matching_usernames = Set.new

          # next if ['application_settings'].include?(table)

          connection.select_rows(sql_query_group_non_null(table, column.name)).flat_map do |id, value|
            json = ::JSON.parse! value
            search = JSONContextSearch.new(
              json,
              filter_integer: json_filter_integer,
              filter_string: json_filter_string,
            )
            next if search.integers.empty? && search.strings.empty?

            search.report(file: file)
            matching_ids |= search.integers.keys
            matching_usernames |= search.strings.keys
            
            suffix = "-#{search.integers.keys.join(',')}-#{search.strings.keys.join(',')}"
            path = "#{DIR_JSON}/#{table}.#{column.name}/#{id}#{suffix}"
            FileUtils.mkdir_p(File.dirname(path))
            JSON.write(path, json)
          end
          next if matching_ids.empty? && matching_usernames.empty?

          file.puts

          #puts "#{table}.#{column.name}:"
          #file.puts "* matching ids: #{matching_ids.to_a}" unless matching_ids.empty?
          #file.puts "* matching usernames: #{matching_usernames.to_a}" unless matching_usernames.empty?
          #file.puts
        end
      end
    end
  end
end

# frozen_string_literal: true

# TODO: deprecate

module ChalmersGitlabFixing
  # Formatting helpers.
  module Format
    def format_table_column(table_column)
      table, column = table_column
      "#{table}.#{column}"
    end

    def report_table_columns(name, table_columns)
      puts "#{name}: #{table_columns.length}"
      return if table_columns.empty?

      table_columns.each do |table_column|
        puts "- #{format_table_column(table_column)}"
      end
      puts
    end

    def format_user(user)
      "#{user.id} (#{user.username})"
    end

    def format_user_mapping(user_source, user_target)
      "#{format_user(user_source)} → #{format_user(user_target)}"
    end

    def format_project(project)
      "#{project.id} (#{project.namespace.path}/#{project.path})"
    end
  end
end

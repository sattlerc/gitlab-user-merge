# frozen_string_literal: true

# Tools for working with the provided user mapping.
module ChalmersGitlabFixing
  module UserMapping
    include SQLExecution

    PATH_USER_MAPPING = ENV.fetch(
      'PATH_USER_MAPPING',
      '/home/sattler/mnt/user-mapping.json'
    )

    def user_mapping
      @user_mapping ||= JSON.read(PATH_USER_MAPPING).transform_keys(&:to_i)
    end

    def versions_user_id
      user_mapping.entries.map { |e| Version.of_pair(e) }
    end

    def duplicated_user_ids
      user_mapping.keys.to_set
    end

    def duplicated_users
      duplicated_user_ids.map { |id| User.find(id) }
    end

    def duplicated_user_usernames
      duplicated_users.map(&:username).to_set
    end

    def duplicated_user_usernames_regex
      @duplicated_user_usernames_regex ||=
        Regexp.new(duplicated_user_usernames.map { |w| Regexp.escape(w) }.join('|'))
    end

    def scan_for_duplicated_user_usernames(string)
      string.scan(duplicated_user_usernames_regex)
    end

    TABLE_USER_MAPPING = '_search_keys'
    VERSION_COLUMN_USER_MAPPING = {
      source: '_id',
      target: '_original_id'
    }.freeze

    def with_table_user_mapping(&block)
      columns = [
        SQL.spacing do |e|
          e << SQL.identifier(VERSION_COLUMN_USER_MAPPING[:source])
          e << 'bigint'
          e << 'PRIMARY KEY'
        end,
        SQL.spacing do |e|
          e << SQL.identifier(VERSION_COLUMN_USER_MAPPING[:target])
          e << 'bigint'
        end
      ]
      execute_create(TABLE_USER_MAPPING, columns, temporary: true)
      begin
        execute_insert(TABLE_USER_MAPPING, user_mapping.entries, multiple: true)
        block.call
      ensure
        execute_drop(TABLE_USER_MAPPING)
      end
    end
  end
end

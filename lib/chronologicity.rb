# frozen_string_literal: true

# Check if timestamps are in order.
module ChalmersGitlabFixing
  module Chronologicity
    include SQLExecution
    include UserMapping
    include Models
    include WithColumnClassification

    def no_activity(user)
      user.last_active_at < user.created_at + 1
    end

    DAY = 24 * 60 * 60

    def precedes?(user, date)
      user.last_active_at.nil? || user.last_active_at + DAY < date
    end

    def version_newer_user_uncached(version_user_id)
      raise 'no user given' if version_user_id.empty?

      version_user = version_user_id.transform_values { |id| user(id) }
      max_created_at = version_user.values.map(&:created_at).max
      version_user.keys.max_by do |v|
        user = version_user[v]
        [
          no_activity(user) ? 0 : 1, # Prefer users with activity.
          precedes?(user, max_created_at) ? 0 : 1, # Prefer users that are not outdated.
          Version.order(v) # Give preference to the source.
        ]
      end
    end

    def version_newer_user(version_user_id)
      @version_newer_user ||= {}
      @version_newer_user[version_user_id] ||= version_newer_user_uncached(version_user_id)
      @version_newer_user[version_user_id]
    end

    def print_version_newer_user(file: $stdout)
      user_mapping.entries.each do |entry|
        version_user_id = Version.of_pair(entry)
        file.puts "#{version_user_id}: #{version_newer_user(version_user_id)}"
      end
    end

    # Outdated below.

    CHONOLOGICITY_CHECKS = {
      %w[organization_users user_id] => %i[created_at updated_at],
      %w[user_details user_id] => [
        :password_last_changed_at # ,
        # :project_authorizations_recalculated_at  # Sometimes not monotone. Maybe recalculations happen for various reasons.
      ],
      %w[user_highest_roles user_id] => %i[updated_at],
      %w[user_preferences user_id] => %i[created_at updated_at],
      %w[users id] => %i[created_at updated_at last_activity_on current_sign_in_at]
    }.freeze

    def identity_providers(user)
      Identity.select { |m| m.user_id == user.id }.to_a.to_h { |m| [m.provider, m.extern_uid] }
    end

    def format_time(time)
      time.utc.strftime('%FT%T')
    end

    def format_user_detailed(user)
      SQL.spacing do |e|
        e << user.id
        e << "@#{user.username}"
        e << user.email
        e << "created_at:#{format_time(user.created_at)}"
        e << "last_active_at:#{format_time(user.last_active_at)}"
        password_last_changed = user_detail(user.id).password_last_changed_at
        unless (password_last_changed - user.created_at).abs < 1
          e << "password_last_changed_at:#{format_time(password_last_changed)}"
        end
        identity_providers(user).entries.each do |provider, extern_uid|
          e << "#{provider}:#{extern_uid}"
        end
      end
    end

    def format_version_user_detailed(version_user)
      xs = version_user.entries.map { |version, user| "#{version}: #{format_user(user)}" }
      "{#{xs.join(', ')}}"
    end

    def check(file: $stdout, strict: true)
      puts 'Checking violations of chronologicity...'
      user_mapping.entries.each do |entry|
        version_user = user_mapping_entry_as_version(entry).transform_values { |id| User.find(id) }
        puts "Checking #{format_version_user_detailed(version_user)}..."

        counterexamples = Enumerator.new do |e|
          CHONOLOGICITY_CHECKS.entries.each do |(table, column), time_columns|
            model = General.from_singleton(models_by_table[table])
            begin
              versions = version_user.transform_values do |user|
                General.from_singleton(model.select { |m| m.send(column) == user.id }.to_a)
              end
            rescue ActiveRecord::RecordNotFound => e
              # puts e
              # next
              raise
            end
            time_columns.each do |time_column|
              values = VERSIONS.to_h { |v| [v, versions[v].send(time_column)] }
              next if values[:target].nil? || values[:source].nil? || values[:target] <= values[:source]

              e << [[table, time_column], values]
              if strict
                raise "Non-monotone table column #{table}.#{time_column} for #{format_version_user_detailed(version_user)}: #{values}"
              end
            end
          end
        end.to_a

        file.puts '* User mapping:'
        version_user.entries.each do |version, user|
          file.puts "  - #{version}: #{format_user(user)}"
        end
        if counterexamples.empty?
          file.puts '  All timestamps chronological.'
        else
          file.puts '  Non-chronological timestamps:'
          counterexamples.each do |(table, time_column), values|
            file.puts "  - #{table}.#{time_column}: #{values}"
          end
        end
        file.puts
      end
    end
  end
end

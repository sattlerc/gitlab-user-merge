# frozen_string_literal: true

module ChalmersGitlabFixing
  # Decision support for version conflicts.
  module Resolution
    ## Resolution actions

    # An action to take for resolving two conflicting values
    class Action
      def combine(_version_value)
        raise 'not implemented'
      end

      def combine_sql(_version_fragment)
        raise 'not implemented'
      end

      def to_s
        self.class.name.demodulize
      end

      def format(version_value)
        SQL.listing do |e|
          e << SQL.format_symbol_hash(version_value)
          e << "resolution #{combine(version_value)} (#{self})"
        end
      end
    end

    # Take a specific version.
    class ActionVersion
      def initialize(version)
        @version = version
      end

      attr_reader :version

      def combine(version_value)
        version_value.fetch(version)
      end

      def combine_sql(version_fragment)
        version_fragment.fetch(version)
      end

      def to_s
        "#{super}(#{version})"
      end

      def format(version_value)
        hash_formatted = General.transform_values_with_key(version_value) do |v, value|
          { value: value, highlight: v == version }
        end
        SQL.format_rich_symbol_hash(hash_formatted)
      end
    end

    # Take the minimum of the two conflicting values.
    # Useful for columns like created_at.
    class ActionMin < Action
      def combine(version_value)
        raise 'no value given' if version_value.empty?

        version_value.compact.values.min
      end

      def combine_sql(version_fragment)
        raise 'no fragment given' if version_fragment.empty?

        SQL.function('LEAST', *version_fragment.values)
      end
    end

    ACTION_MIN = ActionMin.new

    # Take the maximum of the two conflicting values.
    # Useful for columns like projects_limit.
    class ActionMax < Action
      def combine(version_value)
        raise 'no value given' if version_value.empty?

        version_value.compact.values.max
      end

      def combine_sql(version_fragment)
        raise 'no fragment given' if version_fragment.empty?

        SQL.function('GREATEST', *version_fragment.values)
      end
    end

    ACTION_MAX = ActionMax.new

    # Take the maximum of the two conflicting values.
    # Useful for columns like login_count.
    class ActionSum < Action
      def combine(version_value)
        version_value.values.sum
      end

      def combine_sql(version_fragment)
        SQL.op_sum(*version_fragment.values)
      end
    end

    ACTION_SUM = ActionSum.new

    ## Resolutions

    # Interface for resolutions: which cell value to take for conflicting rows when merging users.
    class Resolution
      def initialize(outer, table, column)
        @outer = outer
        @table = table
        @column = column
      end

      attr_reader :outer, :table, :column

      # To override.
      # Whether to ignore this conflict.
      def ignore?
        false
      end

      # To override.
      # Whether to resolve this conflict.
      def resolve?
        true
      end

      def column_user
        outer.relevant_user_column_for_table(table)
      end

      def column_spec
        outer.columns_for_table(table)[column]
      end

      def default
        @default ||= SQL.column_default(column_spec)
      end

      def version_user_id(version_key)
        version_key.transform_values { |values| values.fetch(column_user) }
      end

      def version_user(version_key)
        version_user_id(version_key).transform_values { |id| outer.user(id) }
      end

      def raise_(version_key, version_value, msg)
        raise "#{table}.#{column} with key #{version_key} and value #{version_value}: #{msg}"
      end

      def check_nonempty(version_key, version_value)
        raise_(version_key, version_value, 'no versions given') if version_value.empty?
      end

      # Returns a value of type Action.
      def action(_version_key, _version_value)
        raise 'not implemented'
      end

      def to_s
        self.class.name.demodulize
      end
    end

    # Ignore this conflict.
    # Skipped when reporting conflicts.
    class Ignore < Resolution
      def ignore?
        true
      end
    end

    # Do not resolve this conflict.
    # It will still be reported.
    class DoNotResolve < Resolution
      def resolve?
        false
      end
    end

    # Base class for forwarding to another resolution.
    class Forwarding < Resolution
      def initialize(outer, table, column, resolution)
        super(outer, table, column)
        @resolution = resolution
      end

      attr_reader :resolution

      def action(version_key, version_value)
        resolution.action(version_key, version_value)
      end

      def core_to_s
        Resolution.instance_method(:to_s).bind(self).call
      end

      def to_s
        "#{core_to_s} → #{resolution}"
      end
    end

    # Base class for selecting values.
    # Forwards to another resolution if more than one version left.
    class Selecting < Forwarding
      # returns a set of versions.
      def select(_version_key, _version_value)
        raise 'not implemented'
      end

      def action(version_key, version_value)
        versions = select(version_key, version_value)
        raise_('no selected version') if versions.empty?
        return ActionVersion.new(versions.first) if versions.length == 1

        super(
          version_key.slice(*versions),
          version_value.slice(*versions)
        )
      end
    end

    # Ignore specific values before forwarding to another resolution.
    class IgnoringValues < Selecting
      def initialize(outer, table, column, resolution, values)
        super(outer, table, column, resolution)
        @values = values
      end

      attr_reader :values

      def select(_version_key, version_value)
        version_value.reject { |_, value| values.include?(value) }.keys.to_set
      end

      def core_to_s
        "#{super}(#{SQL.list(values)})"
      end
    end

    # Helper base class.
    class WithDefaults < Selecting
      def initialize(outer, table, column, resolution, defaults: nil)
        super(outer, table, column, resolution)
        @arg_defaults = defaults
      end

      def defaults
        @arg_defaults.nil? ? [default] : @arg_defaults
      end

      def select_rank(_ranks)
        raise 'not implemented'
      end

      def select(_version_key, version_value)
        version_rank = version_value.transform_values do |value|
          index = defaults.find_index(value)
          index = defaults.length if index.nil?
          index
        end
        rank = select_rank(version_rank.values)
        version_value.keys.select { |v| version_rank[v] == rank }.to_set
      end

      def core_to_s
        return super if @arg_defaults.nil?

        "#{super}(defaults: #{SQL.list(@arg_defaults.map { |x| SQL.format_value(x) })})"
      end
    end

    # Choose version according to how far the corresponding value is from being a default.
    # If equally far, forward to the given resolution.
    class PreferNondefaults < WithDefaults
      def select_rank(ranks)
        ranks.max
      end
    end

    # Choose version according to how close the corresponding value is to being a default.
    # If equally far, forward to the given resolution.
    class PreferDefaults < WithDefaults
      def select_rank(ranks)
        ranks.min
      end
    end

    # The resolution action does not depend on the conflict.
    class Constant < Resolution
      def initialize(outer, table, column, action)
        super(outer, table, column)
        @action = action
      end

      def action(_version_key, _version_value)
        @action
      end

      def to_s
        "#{super}(#{@action})"
      end
    end

    # Base class for resolutions that choose a version.
    class Version_ < Resolution
      # Returns the chosen version.
      def version(_version_key, _version_value)
        raise 'not implemented'
      end

      def action(version_key, version_value)
        check_nonempty(version_key, version_value)

        ActionVersion.new(version(version_key, version_value))
      end
    end

    # Chooses the smallest version (i.e., target, if available).
    class Target < Version_
      def version(_version_key, version_value)
        version_value.keys.min_by { |v| Version.order(v) }
      end
    end

    # Chooses the largest version (i.e., source, if available).
    class Source < Version_
      def version(_version_key, version_value)
        version_value.keys.max_by { |v| Version.order(v) }
      end
    end

    # Select the version of the newer user.
    class Newest < Version_
      def version(version_key, _version_value)
        outer.version_newer_user(version_user_id(version_key))
      end
    end

    # Select the versions with the most words (useful for names).
    class SelectMostWords < Selecting
      def select(_version_key, version_value)
        General.maxima(version_value.keys) do |v|
          value = version_value[v]
          value.nil? ? -1 : value.split.length
        end
      end
    end

    # Select the versions with the longest value.
    class SelectLongest < Selecting
      def select(_version_key, version_value)
        General.maxima(version_value.keys) do |v|
          value = version_value[v]
          value.nil? ? -1 : value.length
        end
      end
    end

    # Select the versions with the newest manual password reset.
    class SelectNewestManualPassword < Selecting
      def select(version_key, _version_value)
        version_user = version_user(version_key)
        General.maxima(version_user.keys) do |v|
          user = version_user[v]
          detail = outer.user_detail(user.id)
          user.password_automatically_set ? [0] : [1, detail.password_last_changed_at]
        end
      end
    end

    # Select the versions with the newest ongoing password reset.
    class SelectNewestPasswordReset < Selecting
      def select(version_key, _version_value)
        version_user = version_user(version_key)
        General.maxima(version_user.keys) do |v|
          General.with_nil_bottom(version_user[v].reset_password_sent_at)
        end
      end
    end

    ## Wrappers

    IGNORE = proc do |outer, table, column|
      Ignore.new(outer, table, column)
    end

    DO_NOT_RESOLVE = proc do |outer, table, column|
      DoNotResolve.new(outer, table, column)
    end

    def self.ignoring_values(values, &block)
      proc do |outer, table, column|
        IgnoringValues.new(outer, table, column, block.call.call(outer, table, column), values)
      end
    end

    def self.prefer_nondefaults(defaults: nil, &block)
      proc do |outer, table, column|
        PreferNondefaults.new(outer, table, column, block.call.call(outer, table, column), defaults: defaults)
      end
    end

    def self.prefer_defaults(defaults: nil, &block)
      proc do |outer, table, column|
        PreferDefaults.new(outer, table, column, block.call.call(outer, table, column), defaults: defaults)
      end
    end

    def self.constant(action)
      proc do |outer, table, column|
        Constant.new(outer, table, column, action)
      end
    end

    MIN = constant(ACTION_MIN)
    MAX = constant(ACTION_MAX)
    SUM = constant(ACTION_SUM)

    TARGET = proc do |outer, table, column|
      Target.new(outer, table, column)
    end

    SOURCE = proc do |outer, table, column|
      Source.new(outer, table, column)
    end

    NEWEST = proc do |outer, table, column|
      Newest.new(outer, table, column)
    end

    def self.select_most_words(&block)
      proc do |outer, table, column|
        SelectMostWords.new(outer, table, column, block.call.call(outer, table, column))
      end
    end

    def self.select_longest(&block)
      proc do |outer, table, column|
        SelectLongest.new(outer, table, column, block.call.call(outer, table, column))
      end
    end

    def self.select_newest_manual_password(&block)
      proc do |outer, table, column|
        SelectNewestManualPassword.new(outer, table, column, block.call.call(outer, table, column))
      end
    end

    def self.select_newest_password_reset(&block)
      proc do |outer, table, column|
        SelectNewestPasswordReset.new(outer, table, column, block.call.call(outer, table, column))
      end
    end

    ## Resolution configuration

    # User password: prefer (newer) manually set passwords.
    PASSWORD = select_newest_manual_password { NEWEST }

    # User password reset: prefer newest ongoing reset.
    PASSWORD_RESET = select_newest_password_reset { NEWEST }

    # User email confirmation: prefer default and target.
    EMAIL_CONFIRMATION = prefer_defaults { TARGET }

    # User OTP: default to the less secure.
    OTP = prefer_defaults { NEWEST }

    # User account locking: default to less locked.
    LOCKED = prefer_defaults { NEWEST }

    RESOLUTIONS = {
      %w[notification_settings id] => IGNORE,
      %w[notification_settings created_at] => MIN,
      %w[notification_settings updated_at] => MAX,

      %w[organization_users id] => IGNORE,
      %w[organization_users created_at] => MIN,
      %w[organization_users updated_at] => MAX,

      # Project authorizations.
      # Cache table, we recalculate this later.
      %w[project_authorizations access_level] => IGNORE,
      %w[project_authorizations_for_migration access_level] => IGNORE,
      %w[user_details project_authorizations_recalculated_at] => IGNORE,

      # User highest roles.
      # Cache table, we recalculate this later.
      %w[user_highest_roles highest_access_level] => IGNORE,
      %w[user_highest_roles updated_at] => IGNORE,

      %w[user_details location] => prefer_nondefaults { NEWEST },
      %w[user_details onboarding_status] => prefer_nondefaults { NEWEST },
      %w[user_details pronouns] => prefer_nondefaults(defaults: ['', nil]) { NEWEST },
      %w[user_details pronunciation] => prefer_nondefaults(defaults: ['', nil]) { NEWEST },
      %w[user_details webauthn_xid] => prefer_nondefaults { NEWEST },
      %w[user_details website_url] => prefer_nondefaults(defaults: ['', nil]) { NEWEST },

      %w[user_preferences id] => IGNORE,
      %w[user_preferences created_at] => TARGET,
      %w[user_preferences updated_at] => MAX,
      %w[user_preferences achievements_enabled] => prefer_nondefaults { NEWEST },
      %w[user_preferences dark_color_scheme_id] => prefer_nondefaults { NEWEST },
      %w[user_preferences diffs_addition_color] => prefer_nondefaults(defaults: ['', nil]) { NEWEST },
      %w[user_preferences diffs_deletion_color] => prefer_nondefaults(defaults: ['', nil]) { NEWEST },
      %w[user_preferences enabled_following] => prefer_nondefaults { NEWEST },
      %w[user_preferences first_day_of_week] => prefer_nondefaults { NEWEST },
      %w[user_preferences issues_sort] => prefer_nondefaults { NEWEST },
      %w[user_preferences organization_groups_projects_display] => prefer_nondefaults(defaults: [0]) { NEWEST },
      %w[user_preferences pinned_nav_items] => prefer_nondefaults { NEWEST },
      %w[user_preferences projects_sort] => prefer_nondefaults { NEWEST },
      %w[user_preferences show_whitespace_in_diffs] => prefer_nondefaults { NEWEST },
      %w[user_preferences tab_width] => prefer_nondefaults { NEWEST },
      # Default changed from 0 to 2 in ef167535.
      %w[user_preferences text_editor_type] => prefer_nondefaults(defaults: [0, 2]) { NEWEST },
      %w[user_preferences timezone] => prefer_nondefaults(defaults: ['', nil]) { NEWEST },

      # User email:
      # We prefer the source since an email update typically triggered the duplication.
      # On login via an identity provider (i.e, Entra), the email should update anyway.
      # There is one email address that it seems we should not use.
      %w[users email] => ignoring_values(['julianad_delete@student.chalmers.se']) { SOURCE },

      # User stuff to take from target.
      %w[users created_at] => TARGET,
      %w[users username] => TARGET,
      %w[users confirmed_at] => TARGET,

      # User static object token: not relevant for us since external storage not configured.
      %w[users static_object_token_encrypted] => TARGET,

      # User feed token: cannot know if used, but not critical.
      %w[users feed_token] => TARGET,

      # User sign-in.
      %w[user_details password_last_changed_at] => PASSWORD,
      %w[users encrypted_password] => PASSWORD,
      %w[users password_automatically_set] => PASSWORD,
      %w[users failed_attempts] => SUM,
      %w[users sign_in_count] => SUM,
      %w[users current_sign_in_at] => prefer_nondefaults { NEWEST },
      %w[users current_sign_in_ip] => prefer_nondefaults { NEWEST },
      %w[users last_sign_in_at] => prefer_nondefaults { NEWEST },
      %w[users last_sign_in_ip] => prefer_nondefaults { NEWEST },
      %w[users remember_created_at] => MAX,

      # User activity.
      %w[users last_activity_on] => MAX,
      %w[users updated_at] => MAX,

      # User project limit.
      %w[users projects_limit] => MAX,

      # Non-controversial user stuff.
      %w[users external] => prefer_nondefaults(defaults: [nil, false]) { NEWEST },
      # Default changed from 1 to 3 in d0b339e8
      %w[users color_mode_id] => prefer_nondefaults(defaults: [nil, 1, 3]) { NEWEST },
      %w[users color_scheme_id] => prefer_nondefaults { NEWEST },
      %w[users notification_email] => prefer_nondefaults { NEWEST },
      %w[users public_email] => prefer_nondefaults(defaults: ['', nil]) { NEWEST },
      %w[users hide_project_limit] => prefer_nondefaults { NEWEST },
      # Default changed from 1 to 3 in 1a7decc4
      %w[users theme_id] => prefer_nondefaults(defaults: [nil, 1, 3]) { NEWEST },
      %w[users include_private_contributions] => prefer_nondefaults { NEWEST },
      %w[users commit_email] => prefer_nondefaults(defaults: ['', nil]) { NEWEST },
      %w[users name] => prefer_nondefaults { select_most_words { select_longest { NEWEST } } },
      %w[users hide_no_password] => prefer_nondefaults { NEWEST },
      %w[users private_profile] => prefer_nondefaults { NEWEST },
      %w[users hide_no_ssh_key] => prefer_nondefaults { NEWEST },

      # User avatar: we do not mess with this; it would require moving the picture file.
      %w[users avatar] => TARGET,

      # User email token: replying to older issues will be broken.
      %w[users incoming_email_token] => NEWEST,

      # User email confirmation.
      %w[users confirmation_token] => EMAIL_CONFIRMATION,
      %w[users confirmation_sent_at] => EMAIL_CONFIRMATION,
      %w[users unconfirmed_email] => EMAIL_CONFIRMATION,

      # User password reset.
      %w[users reset_password_token] => PASSWORD_RESET,
      %w[users reset_password_sent_at] => PASSWORD_RESET,

      # User OTP.
      %w[users consumed_timestep] => OTP,
      %w[users encrypted_otp_secret] => OTP,
      %w[users encrypted_otp_secret_iv] => OTP,
      %w[users encrypted_otp_secret_salt] => OTP,
      %w[users otp_backup_codes] => OTP,
      %w[users otp_grace_period_started_at] => OTP,
      %w[users otp_required_for_login] => OTP,
      %w[users otp_secret_expires_at] => OTP,

      # User account locking.
      %w[users locked_at] => LOCKED,
      %w[users unlock_token] => LOCKED
    }.freeze
  end

  module WithResolutions
    include Models
    include Chronologicity

    def resolutions_uncached
      General.transform_values_with_key(Resolution::RESOLUTIONS) do |(table, column), resolution_template|
        resolution_template.call(self, table, column, column)
      end
    end

    def resolutions
      @resolutions ||= resolutions_uncached
    end

    def resolution(table, column)
      resolutions[[table, column]]
    end

    def format_version_value(table, column, version_keys, version_value, resolution: false)
      return SQL.format_symbol_hash(version_value) unless resolution && resolution(table, column).resolve?

      resolution(table, column).action(version_keys, version_value).format(version_value)
    end

    def resolution_sql_queries_for_conflict(table, version_keys, values, deletion: false, &block)
      assignments = Enumerator.new do |e|
        values.entries.each do |column, version_value|
          resolution = resolution(table, column)
          next unless resolution.resolve?

          action = resolution.action(version_keys, version_value)
          next if action.respond_to?(:version) && action.version == :target

          e << [
            column,
            action.combine_sql(Version::VERSIONS.index_with { |v| Version.sql_column(v, column) })
          ]
        end
      end.to_a

      unless assignments.empty?
        update = SQL.spacing do |e|
          e << SQL::UPDATE
          e << SQL.as(SQL.identifier(table), Version.sql(:target))
          e << SQL.set(assignments)
          e << SQL.from(Version::VERSIONS.reject { |v| v == :target }.map { |v| [table, Version.sql(v)] })
          e << SQL.where do |e1|
            Version::VERSIONS.each do |v|
              version_keys[v].entries.each do |key, value|
                e1 << SQL.equals(Version.sql_column(v, key), SQL.value(value))
              end
            end
          end
        end
        block.call(update)
      end
      return unless deletion

      delete = SQL.spacing do |e|
        e << SQL::DELETE
        e << SQL.from(table)
        e << SQL.where(SQL.keys_clause(version_keys[:source]))
      end
      block.call(delete)
    end
  end
end

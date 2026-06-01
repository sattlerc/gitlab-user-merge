module ChalmersGitlabFixing
  # Tools for membership merging.
  class Membership
    include SQLExecution
    include Models
    include UserMapping

    MEMBER_EXPECTED = {
      invite_token: nil,
      requested_at: nil,
      expires_at: nil,
      ldap: false,
      override: false,
      invite_email_success: true,
      state: 0,
      member_role_id: nil,
      expiry_notified_at: nil,
      is_source_accessible_to_current_user: true
    }

    def members_unexpected_attributes
      Enumerator.new do |e|
        versions_user_id.each do |version_user_id|
          version_user_id.values.each do |user_id|
            Member.where(user_id: user_id).select do |member|
              MEMBER_EXPECTED.entries.each do |key, value_expected|
                value = member.send(key)
                e << [member, key, value, value_expected] unless value == value_expected
              end
            end
          end
        end
      end.to_a
    end

    # Checks that the memberships are of the expected form.
    # Currently does not support open invitations or requests.
    def check_members_attributes
      r = members_unexpected_attributes
      return if r.empty?

      puts 'Found members with unexpected attributes:'
      members_unexpected_attributes.each do |member, key, value, value_expected|
        puts "* Member(#{member.id}).#{key} = #{value.inspect} (expected #{value_expected.inspect})"
      end
      raise 'members have unexpected attributes'
    end

    # Weak pruning: only considers memberships of the same namespace.

    # Returns a membership.
    def select_canonical_membership(memberships)
      max_access_level = memberships.map(&:access_level).max
      memberships
        .select { |member| member.access_level == max_access_level }
        .min_by(&:created_at)
    end

    # Returns a tuple of:
    # * set of remaining memberships
    # * hash mapping each redundant memberships to the superceding remaining membership.
    def prune(memberships)
      remaining = Set.new
      redundant = {}

      memberships
        .group_by { |member| member.source.full_path }
        .values
        .each do |memberships|
        s = select_canonical_membership(memberships)
        remaining.add(s)
        memberships.reject { |m| m == s }.each do |member|
          redundant[member] = s
        end
      end

      [remaining, redundant]
    end

    # Working with the hierarchy of memberships.

    def member_hierarchy_path(member)
      member.source.full_path.split('/')
    end

    def membership_hierarchy(memberships)
      General.hierarchy(memberships) do |member|
        [member_hierarchy_path(member), member]
      end
    end

    def access_level_tree(hierarchy, level: nil, &access_level)
      top, dir = hierarchy
      level_new = [level, *top.map(&access_level)].compact.max
      dir = dir.transform_values do |subhierarchy|
        access_level_tree(subhierarchy, level: level_new, &access_level)
      end.compact
      level_new = nil if level_new == level
      return nil if level_new.nil? && dir.empty?

      [level_new, dir]
    end

    def print_access_level_tree(tree, file: $stdout)
      General.print_hierarchy(tree) do |access_level, prefix: nil|
        file.puts "#{prefix}#{access_level.inspect}"
      end
      file.puts
    end

    def membership_needed?(member, access_levels, strict: false)
      desired_access_level = General.hierarchy_get(access_levels, member_hierarchy_path(member)) do |prev, here|
        puts "strict: #{here} vs #{[prev, here].compact.max}"
        strict ? here : [prev, here].compact.max
      end
      !desired_access_level.nil? && member.access_level == desired_access_level
    end

    def prune_memberships_hereditary(memberships, strict: false)
      access_levels = access_level_tree(
        membership_hierarchy(memberships),
        &:access_level
      )

      memberships
        .group_by { |member| member.source.full_path }
        .values
        .map { |entries| entries.select { |m| membership_needed?(m, access_levels, strict: strict) } }
        .reject(&:empty?)
        .map { |ms| ms.min_by(&:created_at) }
    end

    # Formatting tools.

    def print_memberships(memberships, prefix: '', bullet: '-')
      memberships.each do |member|
        puts "#{prefix}#{bullet} #{member.source.full_path}: #{member.access_level}"
      end
    end

    # Getting memeberships.

    def memberships(user_id)
      user(user_id).members.includes(:source)
    end

    def group_memberships(user_id)
      user(user_id).group_members.includes(:source).index_by { |member| member.source.full_path }
    end

    def project_memberships(user_id)
      user(user_id).project_members.includes(:source).index_by { |member| member.source.full_path }
    end

    def version_memberships(version_user_id)
      version_user_id.transform_values { |user_id| memberships(user_id) }
    end

    def redundant_memberships(memberships, memberships_pruned)
      memberships.to_set - memberships_pruned.to_set
    end

    # Formatting and printing.

    def format_membership_without_path(member)
      "<#{format_user_id(member.user_id)}, level #{member.access_level}>"
    end

    def print_redundant_memberships
      versions_user_id.each do |version_user_id|
        memberships = version_memberships(version_user_id).values.flatten(1)

        _remaining, redundant = prune(memberships)
        next if redundant.empty?

        sels = prune_memberships_hereditary(memberships, strict: true)
        sels_weak = prune_memberships_hereditary(memberships, strict: false)
        puts "selected: #{sels.length} vs #{sels_weak.length} vs #{_remaining.length}"


        puts "Redundant memberships for user mapping #{format_version_user_id(version_user_id)}:"
        redundant.entries.each do |m, orig|
          puts "* #{m.source.full_path}: #{format_membership_without_path(m)} (made redundant by #{format_membership_without_path(orig)})"
        end
        puts
      end
    end

    def test
      print_redundant_memberships

      #check_members_attributes
      #return

      #print_project_memberships
      #r = General.hierarchy([[['a'], 1], [['a', 'b'], 2], [[], 3]])
    end
  end
end

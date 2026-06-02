# frozen_string_literal: true

module ChalmersGitlabFixing
  class PersonalProjects
    include ChalmersGitlabFixing::SQLExecution
    include ChalmersGitlabFixing::UserMapping
    include ChalmersGitlabFixing::Models

    def format_project(project)
      "#{project.id} (#{project.namespace.path}/#{project.path})"
    end

    def report_personal_projects
      versions_user_id.each do |version_user_id|
        version_user = version_user_id.transform_values { |id| user(id) }
        version_namespace = version_user.transform_values(&:namespace)
        version_projects = version_namespace.transform_values { |namespace| Project.where(namespace: namespace.id) }
        next if version_projects.all? { |projects| projects.empty? }

        puts "Projects for user mapping #{Version.format_arrow(version_user_id)}:"
        version_projects.entries.each do |v, projects|
          next if projects.empty?

          puts "* #{v.to_s.capitalize} projects (namespace #{version_namespace[v].id}):"
          projects.each do |project|
            puts "  - #{format_project(project)}"
          end
        end
        puts
      end
    end

    def check_personal_projects_for_conflict
      puts 'Checking personal projects for conflicts...'

      good = true
      versions_user_id.each do |version_user_id|
        version_user = version_user_id.transform_values { |id| user(id) }
        version_namespace = version_user.transform_values(&:namespace)
        version_projects = version_namespace.transform_values { |namespace| Project.where(namespace: namespace.id).index_by(&:path) }

        version_projects[:source].merge(version_projects[:target]) do |path, source_project, target_project|
          good = false
          version_project = Version.of_pair(source_project, target_project)
          puts "* Project path conflict for #{Version.format_arrow(version_user_id)}: #{path}"
          Version.VERSIONS.each do |v|
            puts "  - #{v.to_s.capitalize}: #{format_project(version_project[v])}"
          end
          puts
        end
      end
      raise 'project conflicts detected' unless good
    end

    def transfer_personal_projects
      puts 'Transferring personal projects...'
      puts
      versions_user_id.each do |version_user_id|
        version_user = version_user_id.transform_values { |id| user(id) }
        version_namespace = version_user.transform_values(&:namespace)

        Project.where(namespace: version_namespace[:source].id).each do |project|
          puts "Transferring #{format_project(project)}..."
          project.namespace_id = version_namespace[:target].id
          project.save!
          puts "Transferred #{format_project(Project.find(project.id))}."
          puts
        end
      end
    end

    def check_no_personal_projects_for_user_id(user_id)
      Project.where(namespace: user(user_id).namespace.id).each do |project| # rubocop:disable Lint/UnreachableLoop
        raise "personal project #{project}"
      end
    end

    def check_personal_projects_clear
      puts 'Checking no remaining personal projects need transfer...'
      versions_user_id.each do |version_user_id|
        check_no_personal_projects_for_user_id(version_user_id[:source])
      end
    end

    # TODO: move elsewhere

    def refresh_project_authorizations
      puts 'Refreshing project authorizations...'
      worker = AuthorizedProjectsWorker.new
      versions_user_id.each do |version_user_id|
        worker.perform(version_user_id[:target])
      end
    end

    def refresh_user_highest_roles
      puts 'Refreshing user highest roles...'
      versions_user_id.each do |version_user_id|
        Users::UpdateHighestMemberRoleService.new(user(version_user_id[:target])).execute
      end
    end
  end
end

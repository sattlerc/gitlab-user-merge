# frozen_string_literal: true

module GitlabUserMerge
  module Models
    def models_by_table
      h = tables.to_h { |table| [table, []] }
      @models_by_table ||= ApplicationRecord.descendants.each_with_object(h) do |model, h|
        next unless model.table_exists? && !model.abstract_class?
        next if model.module_parents.include?(Gitlab::BackgroundMigration)

        h[model.table_name].append(model)
      end
    end

    def model_for_table(table)
      General.from_singleton(models_by_table[table])
    end

    def user(id)
      @user ||= {}
      @user[id] ||= User.find(id)
      @user[id]
    end

    def user_detail_uncached(user_id)
      r = UserDetail.select { |m| m.user_id == user_id }.to_a
      raise "no user details for user id #{user_id}" if r.empty?

      General.from_singleton(r)
    end

    def user_detail(user_id)
      @user_detail ||= {}
      @user_detail[user_id] ||= user_detail_uncached(user_id)
      @user_detail[user_id]
    end

    def format_user(user)
      "#{user.id} (@#{user.username})"
    end

    def format_user_id(user_id)
      format_user(user(user_id))
    end

    def format_version_user_id(version_user_id)
      Version.format_arrow(version_user_id) do |user_id|
        format_user_id(user_id)
      end
    end

    def format_project(project)
      "#{project.id} (#{project.namespace.path}/#{project.path})"
    end

    def foreign_keys_for_model_uncached(model)
      model.reflections.entries.each_with_object({}) do |entry, h|
        name, reflection = entry
        next unless reflection.is_a?(ActiveRecord::Reflection::BelongsToReflection)

        foreign_key = reflection.foreign_key.to_s

        if reflection.options[:polymorphic]
          parent = :polymorphic
        else
          name_to_table_override = {
            'vulnerability_occurrence' => 'vulnerability_occurrences',
            'push_rule' => 'push_rules'
          }
          parent = name_to_table_override.fetch(name, &proc { reflection.klass.table_name })
          # Deal with mirrors across Main and CI databases.
          parent = {
            'ci_namespace_mirrors' => 'namespaces',
            'ci_project_mirrors' => 'projects'
          }.fetch(parent, parent)
        end

        # Skip extra association.
        # We already know that this has parent table users.
        next if foreign_key == 'user_id' && parent == 'banned_users'

        h.merge!(foreign_key => parent) do |key, old, new|
          if [old, new].include?(:polymorphic)
            :polymorphic
          else
            raise "Duplicate parent for #{model}.#{key}: #{old} and #{new}" unless old == new

            old
          end
        end
      end
    end

    def foreign_keys_for_model(model)
      @foreign_keys_for_model ||= {}
      @foreign_keys_for_model[model] ||= foreign_keys_for_model_uncached(model)
      @foreign_keys_for_model[model]
    end
  end
end

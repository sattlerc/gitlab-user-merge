# frozen_string_literal: true

# Cheap deserialization from JSON structures.
# Not applicable to collections of classes.
module GitlabUserMerge
  module Deserialization
    def deserialize(data)
      instance_values.each do |name, value|
        v = data[name]
        case value
        when Array
          instance_variable_set("@#{name}", v)
        when Set
          instance_variable_set("@#{name}", v.to_set)
        else
          value.deserialize(v)
        end
      end
      self
    end
  end
end

# frozen_string_literal: true

module ChalmersGitlabFixing
  # General utility methods.
  module General
    ## Sorting.

    def self.maxima(collection, &block)
      x_max = block.nil? ? collection.max : collection.max_by(&block)
      max = block.nil? ? x_max : block.call(x_max)
      collection.select { |x| (block.nil? ? x : block.call(x)) == max }
    end

    def self.minima(collection, &block)
      x_min = block.nil? ? collection.min : collection.min_by(&block)
      min = block.nil? ? x_min : block.call(x_min)
      collection.select { |x| (block.nil? ? x : block.call(x)) == min }
    end

    def self.with_nil_bottom(value)
      value.nil? ? [0] : [1, value]
    end

    def self.with_nil_top(value)
      value.nil? ? [1] : [0, value]
    end

    ## Working with data.

    def self.group(collection, &block)
      block = proc { |key, value| [key, value] } if block.nil?

      collection.each_with_object({}) do |x, r|
        key, value = block.call(x)
        values = r[key]
        if values.nil?
          values = []
          r[key] = values
        end
        values.append(value)
      end
    end

    def self.to_h_strict(collection, &block)
      group(collection, &block).transform_values(&method(:from_singleton))
    end

    def self.distribute(hash)
      flat = hash.entries.flat_map do |key_a, value_a|
        value_a.map do |key_b, value_b|
          [key_b, [key_a, value_b]]
        end
      end
      group(flat).transform_values(&method(:group))
    end

    def self.transform_values_with_key(hash, &block)
      hash.to_h { |k, v| [k, block.call(k, v)] }
    end

    def self.from_singleton(collection, allow_empty: false)
      return collection.first if collection.length == 1
      return nil if allow_empty && collection.empty?

      raise "Not a singleton: #{collection}"
    end

    ## Other.

    def self.equal_strictly(value_a, value_b)
      value_a.class == value_b.class && value_a == value_b # rubocop:disable Style/ClassEqualityComparison
    end

    def self.intercalate(value, sequence, default: nil)
      return [default] if sequence.empty?

      first = true
      sequence.flat_map do |y|
        first_orig = first
        first = false
        first_orig ? [y] : [value, y]
      end
    end
  end
end

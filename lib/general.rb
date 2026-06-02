# frozen_string_literal: true

module GitlabUserMerge
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

    def self.hierarchy(entries, &block)
      r = General.group(entries.map(&block)) do |path, value|
        # puts "path #{path}: value #{value}"
        raise 'Ouch' if value.nil?

        if path.empty?
          [nil, value]
        else
          first, *other = path
          # puts "first #{first}, other #{other}"
          [first, [other, value]]
        end
      end
      r.entries.each do |_path, values|
        # puts "path #{path}: values #{values}"
        raise 'X' if values.include?(nil)
      end
      top = r.delete(nil) { [] }
      r.transform_values! { |es| hierarchy(es) }
      [top, r]
    end

    def self.print_hierarchy(hierarchy, key: nil, prefix_bullet: '', prefix_other: '', &print_value)
      return if hierarchy.nil?

      value, dir = hierarchy
      prefix = prefix_bullet
      prefix += "#{key}: " unless key.nil?
      print_value.call(value, prefix: prefix)

      dir.entries.each do |subkey, subhierarchy|
        print_hierarchy(
          subhierarchy,
          key: subkey,
          prefix_bullet: prefix_other + '- ',
          prefix_other: prefix_other + '  ',
          &print_value
        )
      end
    end

    def self.hierarchy_get(hierarchy, path, &combine)
      return nil if hierarchy.nil?

      top, dir = hierarchy
      return top if path.empty?

      raise 'empty path' if path.empty?

      first, *other = path
      r = hierarchy_get(dir[first], other)
      r = combine.call(top, r) unless combine.nil?
      r
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

# frozen_string_literal: true

module GitlabUserMerge
  # JSON tools.
  module JSON
    def self.read(path)
      ::JSON.load_file(path)
    end

    def self.write(path, data)
      File.open(path, 'w') do |file|
        file.puts(::JSON.pretty_generate(data))
      end
    end
  end

  # A JSON visitor pattern mix-in
  module JSONVisitor
    def visit_string(path, data) end
    def visit_integer(path, data) end
    def visit_float(path, data) end
    def visit_bool(path, data) end

    def visit(path, data)
      case data
      when Array
        data.each_with_index do |entry, index|
          path.append(index)
          visit(path, entry)
          path.pop
        end
      when Hash
        data.entries.each do |key, value|
          visit_key(path, key)
          path.append(key)
          visit(path, value)
          path.pop
        end
      when String
        visit_string(path, data)
      when Integer
        visit_integer(path, data)
      when Float
        visit_float(path, data)
      when TrueClass, FalseClass
        visit_bool(path, data)
      end
    end
  end

  class ContextCollector
    attr_reader :result

    # Filtering with callbacks is way too slow, so we use sets.
    def initialize(filter)
      @result = Hash.new { |hash, key| hash[key] = [] }
      @filter = filter
    end

    def add_value(path, value)
      @result[value].append(path.clone) if @filter.include?(value)
    end

    def add_key(path, key)
      add_value([*path, :key], key)
    end

    def report(file: $stdout)
      result.entries.each do |value, paths|
        paths.each do |path|
          file.puts "* #{value}: #{path}"
        end
      end
    end
  end

  class JSONContextSearch
    include JSONVisitor

    def initialize(json, filter_integer: nil, filter_string: nil)
      @filter_integer = filter_integer
      @filter_string = filter_string

      @integers = ContextCollector.new(filter_integer)
      @strings = ContextCollector.new(filter_string)

      visit([], json)
    end

    def integers
      @integers.result
    end

    def strings
      @strings.result
    end

    def report(file: $stdout)
      @integers.report(file: file)
      @strings.report(file: file)
    end

    def visit_integer(path, data)
      @integers.add_value(path, data)
    end

    def visit_string(path, data)
      @strings.add_value(path, data)
    end

    def visit_key(path, data)
      @strings.add_value(path, data)

      x = Integer(data, exception: false)
      @integers.add_value(path, x) unless x.nil?
    end
  end
end

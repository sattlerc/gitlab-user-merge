# frozen_string_literal: true

module ChalmersGitlabFixing
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

  # Base class for collectors
  class Collector
    attr_reader :result

    def initialize
      @result = Set.new
    end

    def collect(data) end

    def self.run(data)
      collector = new
      collector.collect(data)
      collector.result
    end
  end

  # A JSON visitor pattern mix-in
  module JSONVisitor
    def visit_string(data) end
    def visit_integer(data) end
    def visit_float(data) end
    def visit_bool(data) end

    def visit(data)
      case data
      when Array
        data.each do |entry|
          visit(entry)
        end
      when Hash
        data.entries.each do |key, value|
          visit_key(key)
          visit(value)
        end
      when String
        visit_string(data)
      when Integer
        visit_integer(data)
      when Float
        visit_float(data)
      when TrueClass, FalseClass
        visit_bool(data)
      end
    end
  end

  # Collectors of JSON data
  class JSONCollector < Collector
    include JSONVisitor

    def collect(data)
      visit(data)
    end
  end

  # Collector for integers in JSON data.
  class JSONIntegerCollector < JSONCollector
    def visit_integer(data)
      @result.add(data)
    end

    def visit_key(data)
      x = Integer(data, exception: false)
      @result.add(x) unless x.nil?
    end
  end

  # Collector for strings in JSON data.
  class JSONStringCollector < JSONCollector
    def visit_string(data)
      @result.add(data)
    end

    def visit_key(data)
      @result.add(data)
    end
  end
end

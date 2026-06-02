# frozen_string_literal: true

module GitlabUserMerge
  # Combinators for building SQL queries.
  module SQL
    ## Other utilities.

    def self.type_text?(type)
      type == 'text' or type.starts_with?('character varying')
    end

    def self.array_decoder
      PG::TextDecoder::Array.new
    end

    def self.decode_array(array)
      return nil if array.nil?

      array_decoder.decode(array).map(&:to_i)
    end

    # Not complete, add cases as needed.
    def self.convert_from_sql_schema(value, type)
      return nil if value.nil?
      return String(value) if type_text?(type)
      return Time.parse(value) if type.match?('timestamp (with|without) time zone')
      return Integer(value) if %w[smallint bigint integer].include?(type)
      return String(value) if type == 'jsonb'

      if type == 'boolean'
        return true if value == 'true'
        return false if value == 'false'
      end

      raise "unexpected SQL type #{type} for value #{value.inspect}"
    end

    def self.column_default(column_spec)
      convert_from_sql_schema(column_spec.default, column_spec.sql_type_metadata.sql_type)
    end

    ## String utilities.

    def self.collecting(&block)
      Enumerator.new(&block).to_a
    end

    def self.joining(&block)
      collecting(&block).join unless block.nil?
    end

    def self.space(words)
      words.join(' ')
    end

    def self.spacing(&words)
      space(collecting(&words)) unless words.nil?
    end

    def self.list(entries)
      entries.join(', ')
    end

    def self.listing(&entries)
      list(collecting(&entries)) unless entries.nil?
    end

    def self.append(args, extra_arg)
      extra_arg.nil? ? args : [*args, extra_arg]
    end

    def self.with_spacing(args, &block)
      append(args, spacing(&block))
    end

    def self.spacing_if_needed(proc)
      proc.is_a?(Proc) ? spacing(&proc) : proc
    end

    def self.parens(*args, &block)
      args = with_spacing(args, &block)
      raise "expected exactly one effective argument: #{args}" unless args.length == 1

      "(#{args[0]})"
    end

    def self.tuple(values)
      parens(list(values))
    end

    def self.tupling(&values)
      tuple(collecting(&values))
    end

    def self.integer(integer)
      raise "not an integer: #{integer}" unless integer.is_a?(Integer)

      integer.to_s
    end

    def self.string(string)
      raise "not a string: #{string}" unless string.is_a?(String)

      ActiveRecord::Base.connection.quote(string)
    end

    def self.value(value)
      case value
      when Integer
        integer(value)
      when String
        string(value)
      else
        raise "unknown SQL type for value #{value} of type #{value.class}"
      end
    end

    ## Printing utilities.

    def self.format_value(value)
      return 'null' if value.nil?

      value.to_s
    end

    def self.format_symbol_hash(hash, &block)
      block = method(:format_value) if block.nil?

      joining do |e|
        e << '{'
        e << listing do |e1|
          hash.entries.each do |key, value|
            e1 << "#{key}: #{block.call(value)}"
          end
        end
        e << '}'
      end
    end

    def self.format_rich_value(rich_value)
      joining do |e|
        e << '**' if rich_value[:highlight]
        e << format_value(rich_value[:value])
        e << '**' if rich_value[:highlight]
      end
    end

    def self.format_rich_symbol_hash(hash)
      format_symbol_hash(hash, &method(:format_rich_value))
    end

    ## Query building.

    def self.function(name, *args, &block)
      args = with_spacing(args, &block)
      joining do |e|
        e << name
        e << tuple(args)
      end
    end

    def self.operator_binary(operator, left, right)
      spacing do |e|
        e << left
        e << operator
        e << right
      end
    end

    def self.plus(*args)
      operator_binary('+', *args)
    end

    def self.op_sum(*args)
      return integer(0) if args.empty?

      first, *other = args
      other.reduce(first) { |a, b| plus(a, b) }
    end

    def self.upper_bound(arg)
      function('COALESCE', plus(function('MAX', arg), integer(1)), integer(0))
    end

    def self.equals(*args)
      operator_binary('=', *args)
    end

    def self.less(*args)
      operator_binary('<', *args)
    end

    def self.not_(condition)
      spacing do |e|
        e << 'NOT'
        e << condition
      end
    end

    def self.and_(*condition)
      space(General.intercalate('AND', condition, default: integer(1)))
    end

    def self.or_(*condition)
      space(General.intercalate('OR', condition, default: integer(0)))
    end

    def self.anding(&words)
      and_(*collecting(&words)) unless words.nil?
    end

    def self.identifier(identifier)
      ActiveRecord::Base.connection.quote_table_name(identifier.to_s)
      # equivalently:
      # ActiveRecord::Base.connection.quote_column_name(column)
    end

    def self.table(table)
      spacing do |e|
        e << 'TABLE'
        e << identifier(table)
      end
    end

    def self.table_column(table, column)
      [identifier(table), identifier(column)].join('.')
    end

    def self.as(fragment, name)
      spacing do |e|
        e << fragment
        unless name.nil?
          e << 'AS'
          e << identifier(name)
        end
      end
    end

    def self.list_as(entries, identifier: false)
      entries = [entries] unless entries.is_a?(Array)
      listing do |e|
        entries.each do |entry_as|
          entry_as = [entry_as, nil] unless entry_as.is_a?(Array)
          entry_as[0] = identifier(entry_as[0]) if identifier
          e << as(*entry_as)
        end
      end
    end

    def self.set(assignments)
      spacing do |e|
        e << 'SET'
        e << listing do |e1|
          assignments.each do |target, value|
            e1 << equals(identifier(target), value)
          end
        end
      end
    end

    def self.values(entries, multiple: false)
      entries = [entries] unless multiple
      spacing do |e|
        e << 'VALUES'
        e << list(entries.map { |entry| tuple(entry) })
      end
    end

    def self.from(tables)
      spacing do |e|
        next if tables.nil?

        e << 'FROM'
        e << list_as(tables, identifier: true)
      end
    end

    def self.where(*args, &block)
      args = append(args, anding(&block))
      spacing do |e|
        e << 'WHERE'
        e << and_(*args)
      end
    end

    def self.limit(limit: 1)
      spacing do |e|
        e << 'LIMIT'
        e << integer(limit)
      end
    end

    def self.keys_clause(keys)
      SQL.anding do |e|
        keys.entries.each do |key, value|
          e << SQL.equals(SQL.identifier(key), SQL.value(value))
        end
      end
    end

    SELECT = 'SELECT'
    UPDATE = 'UPDATE'
    DELETE = 'DELETE'

    DISTINCT = 'DISTINCT'
    ALL = '*'

    def self.create(table, columns, temporary: false)
      spacing do |e|
        e << 'CREATE'
        e << 'TEMPORARY' if temporary
        e << table(table)
        e << tuple(columns)
      end
    end

    def self.drop(table)
      spacing do |e|
        e << 'DROP'
        e << table(table)
      end
    end

    def self.insert(table, values, columns: nil, multiple: false)
      spacing do |e|
        e << 'INSERT'
        e << 'INTO'
        e << identifier(table)
        e << tuple(columns) unless columns.nil?
        e << values(values, multiple: multiple)
      end
    end
  end

  # Query execution.
  module SQLExecution
    def connection
      ActiveRecord::Base.connection
    end

    def select_unique(query)
      r = connection.select_all(query)
      raise "Non-unique result for SQL query #{query}" unless r.length == 1

      r[0]
    end

    def select_unique_by_keys(table, keys)
      query = SQL.spacing do |e|
        e << SQL::SELECT
        e << SQL::ALL
        e << SQL.from(table)
        e << SQL.where(SQL.keys_clause(keys))
      end
      select_unique(query)
    end

    def execute(&block)
      connection.execute(SQL.spacing(&block))
    end

    def execute_create(*args, **kwargs)
      connection.execute(SQL.create(*args, **kwargs))
    end

    def execute_drop(*args, **kwargs)
      connection.execute(SQL.drop(*args, **kwargs))
    end

    def execute_insert(*args, **kwargs)
      connection.execute(SQL.insert(*args, **kwargs))
    end

    def tables
      connection.tables
    end

    def inhabited_tables
      @inhabited_tables ||= tables.select do |table|
        execute do |e|
          e << SQL::SELECT
          e << SQL.function('EXISTS') do |e1|
            e1 << SQL::SELECT
            e1 << SQL.integer(1)
            e1 << SQL.from(table)
          end
        end
      end.to_set
    end

    def primary_keys(table)
      primary_key = connection.primary_key(table)
      primary_key = [primary_key] if primary_key.is_a?(String)
      primary_key
    end

    def first_primary_key(table)
      primary_keys(table)[0]
    end

    def row_id(table, column)
      key = first_primary_key(table)
      if !key.nil?
        function('min', SQL.identifier(key))
      else
        spacing do |e|
          e << SQL.function('ROW_NUMBER')
          e << 'OVER'
          e << SQL.parens do |e1|
            e1 << 'PARTITION'
            e1 << 'BY'
            e1 << SQL.identifier(column)
          end
        end
      end
    end

    def columns_for_table_uncached(table)
      connection.columns(table).to_h do |column|
        [column.name, column]
      end
    end

    def columns_for_table(table)
      @columns_for_table ||= {}
      @columns_for_table[table] ||= columns_for_table_uncached(table)
      @columns_for_table[table]
    end

    def foreign_keys_by_column_for_table_uncached(table)
      General.group(connection.foreign_keys(table)) do |foreign_key|
        [foreign_key.options[:column], foreign_key]
      end
    end

    def foreign_keys_by_column_for_table(table)
      @foreign_keys_by_column_for_table ||= {}
      @foreign_keys_by_column_for_table[table] ||= foreign_keys_by_column_for_table_uncached(table)
      @foreign_keys_by_column_for_table[table]
    end

    def foreign_key(table, column)
      General.from_singleton(foreign_keys_by_column_for_table(table)
        .fetch(column, [])
        .map { |foreign_key| foreign_key.options[:column] }
        .reject { |column| column.is_a?(Array) } # Partitioning based on [...]partition_id or runner_id.
        .to_set, allow_empty: true)
    end

    def polymorphic_type_column(table, column)
      stem = column.name.delete_suffix('_id')
      return nil if stem == column.name

      column_type_name = "#{stem}_type"
      column_type = columns_for_table(table)[column_type_name]
      return nil if column_type.nil?
      return nil unless SQL.type_text?(column_type.sql_type)

      column_type
    end
  end
end

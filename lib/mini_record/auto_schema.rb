module MiniRecord
  module AutoSchema
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods

      def schema_tables
        @@_schema_tables ||= []
      end

      def table_definition
        return superclass.table_definition unless superclass == ActiveRecord::Base

        @_table_definition ||= begin
          tb = ActiveRecord::ConnectionAdapters::TableDefinition.new(connection)
          tb.primary_key(primary_key)
          tb
        end
      end

      def indexes
        return superclass.indexes unless superclass == ActiveRecord::Base

        @_indexes ||= {}
      end

      def col(*args)
        return unless connection?

        options = args.extract_options!
        type = options.delete(:as) || options.delete(:type) || :string
        args.each do |column_name|
          table_definition.send(type, column_name, options)
          column_name = table_definition.columns[-1].name
          case index_name = options.delete(:index)
          when Hash
            add_index(options.delete(:column) || column_name, index_name)
          when TrueClass
            add_index(column_name)
          when String, Symbol, Array
            add_index(index_name)
          end
        end
      end
      alias :key :col
      alias :property :col
      alias :field :col
      alias :attribute :col

      def timestamps
        col :created_at, :updated_at, :as => :datetime
      end

      def reset_table_definition!
        @_table_definition = nil
      end
      alias :reset_schema! :reset_table_definition!

      def schema
        reset_table_definition!
        yield table_definition
        table_definition
      end
      alias :keys :schema
      alias :properties :schema
      alias :fields :schema
      alias :attributes :schema

      def add_index(column_name, options={})
        index_name = connection.index_name(table_name, :column => column_name)
        indexes[index_name] = options.merge(:column => column_name)
        index_name
      end
      alias :index :add_index

      def connection?
        !!connection
      rescue Exception => e
        puts "\e[31m%s\e[0m" % e.message.strip
        false
      end

      def clear_tables!
        # Drop unsued tables
        (connection.tables - schema_tables).each do |name|
          connection.drop_table(name)
          schema_tables.delete(name)
        end
      end

      def auto_upgrade!
        return unless connection?

        if self == ActiveRecord::Base
          descendants.each(&:auto_upgrade!)
          clear_tables!
        else
          # Table doesn't exist, create it
          unless connection.tables.include?(table_name)
            # TODO: create_table options
            class << connection; attr_accessor :table_definition; end unless connection.respond_to?(:table_definition=)
            connection.table_definition = table_definition
            connection.create_table(table_name)
            connection.table_definition = ActiveRecord::ConnectionAdapters::TableDefinition.new(connection)
          end

          # Add this to our schema tables
          schema_tables << table_name unless schema_tables.include?(table_name)

          # Grab database columns
          fields_in_db = connection.columns(table_name).inject({}) do |hash, column|
            hash[column.name] = column
            hash
          end

          # Generate fields from associations
          if reflect_on_all_associations.any?
            reflect_on_all_associations.each do |association|
              id_key = if association.options[:foreign_key]
                association.options[:foreign_key]
              else
                "#{association.name.to_s}_id".to_sym
              end
              type_key = "#{association.name.to_s}_type".to_sym
              case association.macro
              when :belongs_to
                table_definition.send(:integer, id_key)
                if association.options[:polymorphic]
                  table_definition.send(:string, type_key)
                  add_index [id_key, type_key]
                else
                  add_index id_key
                end
              when :has_and_belongs_to_many
                table = [table_name, association.name.to_s].sort.join("_")
                index = ""
                unless connection.tables.include?(table)
                  connection.create_table(table)
                  connection.add_column table, "#{table.singularize}_id", :integer
                  connection.add_column table, "#{association.name.to_s.singularize}_id", :integer
                  connection.add_index table.to_sym, ["#{table.singularize}_id", "#{association.name.to_s.singularize}_id"].sort.map(&:to_sym), association.options
                end
                # Add join table to our schema tables
                schema_tables << table unless schema_tables.include?(table)
              end
            end
          end

          # Grab new schema
          fields_in_schema = table_definition.columns.inject({}) do |hash, column|
            hash[column.name.to_s] = column
            hash
          end

          # Add to schema inheritance column if necessary
          if descendants.present? && !fields_in_schema.include?(inheritance_column.to_s)
            table_definition.column inheritance_column, :string
          end

          # Remove fields from db no longer in schema
          (fields_in_db.keys - fields_in_schema.keys & fields_in_db.keys).each do |field|
            column = fields_in_db[field]
            connection.remove_column table_name, column.name
          end

          # Add fields to db new to schema
          (fields_in_schema.keys - fields_in_db.keys).each do |field|
            column  = fields_in_schema[field]
            options = {:limit => column.limit, :precision => column.precision, :scale => column.scale}
            options[:default] = column.default if !column.default.nil?
            options[:null]    = column.null    if !column.null.nil?
            connection.add_column table_name, column.name, column.type.to_sym, options
          end

          # Change attributes of existent columns
          (fields_in_schema.keys & fields_in_db.keys).each do |field|
            if field != primary_key #ActiveRecord::Base.get_primary_key(table_name)
              changed  = false  # flag
              new_type = fields_in_schema[field].type.to_sym
              new_attr = {}

              # First, check if the field type changed
              if fields_in_schema[field].type.to_sym != fields_in_db[field].type.to_sym
                changed = true
              end

              # Special catch for precision/scale, since *both* must be specified together
              # Always include them in the attr struct, but they'll only get applied if changed = true
              new_attr[:precision] = fields_in_schema[field][:precision]
              new_attr[:scale]     = fields_in_schema[field][:scale]

              # Next, iterate through our extended attributes, looking for any differences
              # This catches stuff like :null, :precision, etc
              fields_in_schema[field].each_pair do |att,value|
                next if att == :type or att == :base or att == :name # special cases
                if !value.nil? && value != fields_in_db[field].send(att)
                  new_attr[att] = value
                  changed = true
                end
              end

              # Change the column if applicable
              connection.change_column table_name, field, new_type, new_attr if changed
            end
          end

          # Remove old index
          # TODO: remove index from habtm t
          indexes_in_db = connection.indexes(table_name).map(&:name)
          (indexes_in_db - indexes.keys).each do |name|
            connection.remove_index(table_name, :name => name)
          end

          # Add indexes
          indexes.each do |name, options|
            options = options.dup
            unless connection.indexes(table_name).detect { |i| i.name == name }
              connection.add_index(table_name, options.delete(:column), options)
            end
          end

          # Reload column information
          reset_column_information
        end

      end
    end # ClassMethods
  end # AutoSchema
end # MiniRecord

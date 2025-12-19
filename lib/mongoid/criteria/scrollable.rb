module Mongoid
  class Criteria
    module Scrollable
      include Mongoid::Criteria::Scrollable::Fields
      include Mongoid::Criteria::Scrollable::Cursors

      def scroll(cursor_or_type = nil, &_block)
        cursor, cursor_type = cursor_and_type(cursor_or_type)
        raise_multiple_sort_fields_error if multiple_sort_fields?
        criteria = dup
        criteria.merge!(default_sort) if no_sort_option?
        cursor_options = build_cursor_options(criteria)
        cursor = new_cursor(cursor_type, cursor, cursor_options) unless cursor.is_a?(cursor_type)
        raise_mismatched_sort_fields_error!(cursor, cursor_options) if different_sort_fields?(cursor, cursor_options)
        records = find_records(criteria, cursor)
        if block_given?
          previous_cursor = nil
          current_cursor = nil
          records.each do |record|
            previous_cursor ||= cursor_from_record(cursor_type, record, cursor_options.merge(type: :previous))
            current_cursor ||= cursor_from_record(cursor_type, record, cursor_options.merge(include_current: true))
            iterator = Mongoid::Criteria::Scrollable::Iterator.new(
              previous_cursor: previous_cursor,
              next_cursor: cursor_from_record(cursor_type, record, cursor_options),
              current_cursor: current_cursor
            )
            yield record, iterator
          end
        else
          records
        end
      end

      private

      def raise_multiple_sort_fields_error
        raise Mongoid::Scroll::Errors::MultipleSortFieldsError.new(sort: criteria.options.sort)
      end

      def multiple_sort_fields?
        return false unless options.sort
        return false if options.sort.values.first.is_a?(Hash) && options.sort.values.first.key?('$meta') && options.sort.keys.size <= 2

        options.sort.keys.size != 1
      end

      def no_sort_option?
        options.sort.blank? || options.sort.empty?
      end

      def default_sort
        asc(:_id)
      end

      def scroll_field(criteria)
        sort_key = criteria.options.sort.keys.first

        return '_id' if criteria.options.sort[sort_key].is_a?(Hash) && criteria.options.sort[sort_key].key?('$meta')

        sort_key
      end

      def scroll_direction(criteria)
        sort_value = criteria.options.sort.values.first

        return 1 if sort_value.is_a?(Hash) && sort_value.key?('$meta')

        sort_value.to_i
      end

      def build_cursor_options(criteria)
        {
          field_type: scroll_field_type(criteria),
          field_name: scroll_field(criteria),
          direction: scroll_direction(criteria)
        }
      end

      def new_cursor(cursor_type, cursor, cursor_options)
        cursor_type.new(cursor, cursor_options)
      end

      def find_records(criteria, cursor)
        cursor_criteria = criteria.dup
        cursor_criteria.selector = { '$and' => [criteria.selector, cursor.criteria] }

        if cursor.type == :previous
          pipeline = [
            { '$match' => cursor_criteria.selector },
            { '$sort' => { cursor.field_name => -cursor.direction } },
            { '$limit' => criteria.options[:limit] },
            { '$sort' => { cursor.field_name => cursor.direction } }
          ]
          aggregation = cursor_criteria.view.aggregate(pipeline)
          aggregation.map { |record| Mongoid::Factory.from_db(cursor_criteria.klass, record) }

        else
          cursor_criteria = cursor_criteria.order_by(_id: scroll_direction(criteria))
          cursor_criteria
        end
      end

      def cursor_from_record(cursor_type, record, cursor_options)
        cursor_type.from_record(record, cursor_options)
      end

      def scroll_field_type(criteria)
        scroll_field = scroll_field(criteria)
        field = criteria.klass.fields[scroll_field.to_s]

        return field_type(field) if field

        parts = scroll_field.to_s.split('.')
        klass = criteria.klass

        parts.each_with_index do |part, index|
          field = klass.fields[part]

          if field
            klass = field.options[:type] if index < parts.size - 1 && field.options[:type]&.include?(Mongoid::Document)
            next
          end

          relation = klass.relations[part.to_s]
          if relation&.embedded?
            klass = relation.klass
            next
          end

          raise ArgumentError, "Scroll field '#{scroll_field}' not found in #{criteria.klass} (stuck at '#{part}')"
        end

        raise ArgumentError, "Scroll field '#{scroll_field}' not found in #{criteria.klass}" unless field

        field_type(field)
      end

      def field_type(field)
        if field.respond_to?(:foreign_key?) && field.foreign_key? && field.object_id_field?
          BSON::ObjectId
        else
          field.type
        end
      end

    end
  end
end

Mongoid::Criteria.include Mongoid::Criteria::Scrollable

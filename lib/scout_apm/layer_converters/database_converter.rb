# frozen_string_literal: true

module ScoutApm
  module LayerConverters
    class DatabaseConverter < ConverterBase
      def initialize(*)
        super
        @db_query_metric_set = DbQueryMetricSet.new(context)
      end

      def register_hooks(walker)
        super

        return unless scope_layer

        scope_name = scope_layer.legacy_metric_name
        walker.on do |layer|
          next if skip_layer?(layer)
          record_layer(layer, scope_name)
        end
      end

      def record!
        return nil if @db_query_metric_set.metrics.empty?

        # Everything in the metric set here is from a single transaction, which
        # we want to keep track of. (One web call did a User#find 10 times, but
        # only due to 1 http request)
        @db_query_metric_set.increment_transaction_count!
        @store.track_db_query_metrics!(@db_query_metric_set)

        nil # not returning anything in the layer results ... not used
      end

      def skip_layer?(layer)
        layer.type != 'ActiveRecord' ||
          layer.limited? ||
          super
      end

      private


      # If we can't name the model, default to:
      DEFAULT_MODEL = "SQL"

      # If we can't name the operation, default to:
      DEFAULT_OPERATION = "other"

      # layer.name is "Model/operation"; slice directly on single "/" to avoid
      # allocating an intermediate array on the common path, falling back to
      # #split("/") for edge shapes so behavior stays identical.
      def record_layer(layer, scope_name)
        name_str = layer.name.to_s
        slash = name_str.index("/")
        if slash && slash > 0 && name_str.index("/", slash + 1).nil? && (op_len = name_str.length - slash - 1) > 0
          model_name = name_str[0, slash]
          operation = name_str[slash + 1, op_len]
        else
          parts = name_str.split("/")
          model_name = parts.first || DEFAULT_MODEL
          operation = parts[1] || DEFAULT_OPERATION
        end

        @db_query_metric_set.record!(
          model_name,
          operation,
          scope_name,
          1,
          layer.total_call_time,
          records_returned(layer)
        )
      end

      def records_returned(layer)
        if layer.annotations
          layer.annotations.fetch(:record_count, 0)
        else
          0
        end
      end
    end
  end
end

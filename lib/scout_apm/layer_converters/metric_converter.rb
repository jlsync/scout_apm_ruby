# frozen_string_literal: true

# Take a TrackedRequest and turn it into a hash of:
#   MetricMeta => MetricStats

# Full metrics from this request. These get aggregated in Store for the
# overview metrics, or stored permanently in a SlowTransaction
# Some merging of metrics will happen here, so if a request calls the same
# ActiveRecord or View repeatedly, it'll get merged.
module ScoutApm
  module LayerConverters
    class MetricConverter < ConverterBase
      def register_hooks(walker)
        super

        @metrics = {}
        @scope_layer_metric_meta = nil
        @scoped_metric_metas = nil

        return unless scope_layer

        walker.on do |layer|
          next if skip_layer?(layer)

          # The scope layer is recorded unscoped. Every other layer is scoped to
          # it and named only by its type, so there is one MetricMeta per type
          # (not one for all scoped layers) - build each once instead of once
          # per layer.
          if layer == scope_layer
            meta = (@scope_layer_metric_meta ||= MetricMeta.new(layer.legacy_metric_name))
            scoped = false
          else
            # we don't need to use the full metric name for scoped metrics as we only display metrics aggregrated
            # by type.
            scoped_metas = (@scoped_metric_metas ||= {})
            meta = scoped_metas[layer.type] ||=
                     MetricMeta.new(layer.type, :scope => scope_layer.legacy_metric_name)
            scoped = true
          end

          @metrics[meta] ||= MetricStats.new(scoped)

          stat = @metrics[meta]
          stat.update!(layer.total_call_time, layer.total_exclusive_time)
        end
      end

      def record!
        @store.track!(@metrics)
        @metrics  # this result must be returned so it can be accessed by transaction callback extensions
      end
    end
  end
end

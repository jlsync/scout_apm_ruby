# frozen_string_literal: true

module ScoutApm
  module LayerConverters
    class ConverterBase

      attr_reader :context
      attr_reader :request
      attr_reader :root_layer
      attr_reader :layer_finder

      def initialize(context, request, layer_finder, store=nil)
        @context = context
        @request = request
        @layer_finder = layer_finder
        @store = store

        @root_layer = request.root_layer
        # Both of these are created lazily - a converter is instantiated for
        # each recorded request, and most of them never collect a backtrace or
        # see a subscopable layer.
        @backtraces = nil
        @subscope_layers = nil
        @limited = false
      end

      def scope_layer
        layer_finder.scope
      end

      ################################################################################
      # Subscoping
      ################################################################################
      #
      # Keep a list of subscopes, but only ever use the front one.  The rest
      # get pushed/popped in cases when we have many levels of subscopable
      # layers.  This lets us push/pop without otherwise keeping track very closely.
      def register_hooks(walker)
        walker.before do |layer|
          if layer.subscopable?
            (@subscope_layers ||= []).push(layer)
          end
        end

        walker.after do |layer|
          if layer.subscopable?
            @subscope_layers.pop
          end
        end
      end

      def subscoped?(layer)
        subs = @subscope_layers
        subs && subs.first && layer != subs.first # Don't scope under ourself.
      end

      def subscope_name
        @subscope_layers.first.legacy_metric_name
      end


      ################################################################################
      # Backtrace Handling
      ################################################################################
      #
      # Because we get several layers for the same thing if you call an
      # instrumented thing repeatedly, and only some of them may have
      # backtraces captured, we store the backtraces off into another spot
      # during processing, then at the end, we loop over those saved
      # backtraces, putting them back into the metrics hash.
      #
      # This comes up most often when capturing n+1 backtraces. Because the
      # query may be fast enough to evade our time-limit based backtrace
      # capture, only the Nth item (see TrackedRequest for more detail) has a
      # backtrack captured.  This sequence makes sure that we report up that
      # backtrace in the aggregated set of metrics around that call.

      # Call this as you are processing each layer. It will store off backtraces
      def store_backtrace(layer, meta)
        return unless layer.backtrace

        bt = ScoutApm::Utils::BacktraceParser.new(layer.backtrace).call
        if bt.any?
          meta.backtrace = bt
          (@backtraces ||= []) << meta
        end
      end

      # Call this after you finish walking the layers, and want to take the
      # set-aside backtraces and place them into the metas they match
      def attach_backtraces(metric_hash)
        return metric_hash unless @backtraces

        @backtraces.each do |meta_with_backtrace|
          metric_hash.keys.find { |k| k == meta_with_backtrace }.backtrace = meta_with_backtrace.backtrace
        end
        metric_hash
      end


      ################################################################################
      # Limit Handling
      ################################################################################

      # To prevent huge traces from being generated, we should stop collecting
      # detailed metrics as we go beyond some reasonably large count.
      #
      # We should still add up the /all aggregates.

      MAX_METRICS = 500

      def over_metric_limit?(metric_hash)
        if metric_hash.size > MAX_METRICS
          @limited = true
        else
          false
        end
      end

      def limited?
        !! @limited
      end

      ################################################################################
      # Meta Scope
      ################################################################################

      # Reused for the "no scope" / "no desc" cases so we don't allocate an
      # empty Hash per layer. `#merge` below returns a fresh Hash, and nothing
      # downstream mutates these.
      NO_META_OPTIONS = {}.freeze

      # When we make MetricMeta records, we need to determine a few things from layer.
      def make_meta_options(layer)
        scope_hash = make_meta_options_scope(layer)
        desc_hash = make_meta_options_desc_hash(layer)

        return scope_hash if desc_hash.empty?

        scope_hash.merge(desc_hash)
      end

      def make_meta_options_scope(layer)
        # This layer is scoped under another thing. Typically that means this is a layer under a view.
        # Like: Controller -> View/users/show -> ActiveRecord/user/find
        #   in that example, the scope is the View/users/show
        if subscoped?(layer)
          {:scope => subscope_name}

        # We don't scope the controller under itself
        elsif layer == scope_layer
          NO_META_OPTIONS

        # This layer is a top level metric ("ActiveRecord", or "HTTP" or
        # whatever, directly under the controller), so scope to the
        # Controller
        else
          # The scope layer doesn't change while a request is recorded, so this
          # Hash (and the legacy_metric_name it holds) can be reused.
          @scope_meta_options ||= {:scope => scope_layer.legacy_metric_name}
        end
      end

      def make_meta_options_desc_hash(layer, max_desc_length=32768)
        if layer.desc
          desc_s = layer.desc.to_s
          trimmed_desc = desc_s[0 .. max_desc_length]
          {:desc => trimmed_desc}
        else
          NO_META_OPTIONS
        end
      end


      ################################################################################
      # Storing metrics into the hashes
      ################################################################################

      # This is the detailed metric - type, name, backtrace, annotations, etc.
      def store_specific_metric(layer, metric_hash, allocation_metric_hash)
        return false if over_metric_limit?(metric_hash)

        meta_options = make_meta_options(layer)

        meta = MetricMeta.new(layer.legacy_metric_name, meta_options)
        meta.extra.merge!(layer.annotations) if layer.annotations

        store_backtrace(layer, meta)

        metric_hash[meta] ||= MetricStats.new(meta_options.has_key?(:scope))
        allocation_metric_hash[meta] ||= MetricStats.new(meta_options.has_key?(:scope))

        # timing
        stat = metric_hash[meta]
        stat.update!(layer.total_call_time, layer.total_exclusive_time)

        # allocations
        stat = allocation_metric_hash[meta]
        stat.update!(layer.total_allocations, layer.total_exclusive_allocations)

        if LimitedLayer === layer
          metric_hash[meta].call_count = layer.count
          allocation_metric_hash[meta].call_count = layer.count
        end
      end

      # Merged Metric - no specifics, just sum up by type (ActiveRecord, View, HTTP, etc)
      def store_aggregate_metric(layer, metric_hash, allocation_metric_hash)
          meta = aggregate_meta(layer.type)

          metric_hash[meta] ||= MetricStats.new(false)
          allocation_metric_hash[meta] ||= MetricStats.new(false)

          # timing
          stat = metric_hash[meta]
          stat.update!(layer.total_call_time, layer.total_exclusive_time)

          # allocations
          stat = allocation_metric_hash[meta]
          stat.update!(layer.total_allocations, layer.total_exclusive_allocations)
      end

      # The aggregate metric only depends on the layer's type, so reuse a single
      # MetricMeta per type rather than building one per layer.
      def aggregate_meta(type)
        @aggregate_metas ||= {}
        @aggregate_metas[type] ||= MetricMeta.new("#{type}/all")
      end

      ################################################################################
      # Misc Helpers
      ################################################################################

      # Sometimes we start capturing a layer without knowing if we really
      # want to make an entry for it.  See ActiveRecord instrumentation for
      # an example. We start capturing before we know if a query is cached
      # or not, and want to skip any cached queries.
      def skip_layer?(layer)
        return false if layer.annotations.nil?
        return true  if layer.annotations[:ignorable]
      end
    end
  end
end

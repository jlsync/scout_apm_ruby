# frozen_string_literal: true

module ScoutApm
  class MetricSet
    # We can't aggregate a handful of things like samplers (CPU, Memory), or
    # Controller, and Percentiles so pass through these metrics directly
    #
    # TODO: Figure out a way to not have this duplicate what's in Samplers, and also on server's ingest
    PASSTHROUGH_METRICS = ["CPU", "Memory", "Instance", "Controller", "SlowTransaction", "Percentile", "Job"]

    # Hash form of the list above, for O(1) lookups as metrics are absorbed.
    PASSTHROUGH_METRICS_LOOKUP = PASSTHROUGH_METRICS.each_with_object({}) { |type, memo| memo[type] = true }.freeze

    attr_reader :metrics

    def initialize
      @metrics = Hash.new
      @agg_metas = nil
      @errors_agg_metas = nil
      @combine_in_progress = false
    end

    def absorb_all(metrics)
      return if metrics.nil?
      # Yielding two block args avoids Array(metrics) and per-entry [meta, stat]
      # pair allocations when absorbing from a Hash (and destructures Arrays too).
      metrics.each { |meta, stat| absorb_pair(meta, stat) }
    end

    # Absorbs a single new metric into the aggregates
    def absorb(metric)
      meta, stat = metric
      absorb_pair(meta, stat)
    end

    private

    def absorb_pair(meta, stat)
      type = meta.type

      if PASSTHROUGH_METRICS_LOOKUP[type] # Leave as-is, don't attempt to combine into an /all key
        combine_into(meta, stat)

      elsif type == "Errors" # Sadly special cased, we want both raw and aggregate values
        # When combining MetricSets between different 
        combine_into(meta, stat)

        if !@combine_in_progress
          scope = meta.scope
          agg_meta = (@errors_agg_metas ||= {})[scope] ||=
            MetricMeta.new("Errors/Request", :scope => scope)
          combine_into(agg_meta, stat)
        end

      else # Combine down to a single /all key
        by_type = (@agg_metas ||= {})[type] ||= {}
        scope = meta.scope
        agg_meta = by_type[scope] ||= MetricMeta.new("#{type}/all", :scope => scope)
        combine_into(agg_meta, stat)
      end
    end

    def combine_into(meta, stat)
      existing = @metrics[meta]
      if existing
        existing.combine!(stat)
      else
        created = MetricStats.new
        created.combine!(stat)
        @metrics[meta] = created
      end
    end

    public

    # Sets a combine_in_progress flag to prevent double-counting Error metrics.
    # Without it, the Errors/Request number would be increasingly off as
    # metric_sets get merged in.
    def combine!(other)
      @combine_in_progress = true
      absorb_all(other.metrics)
      @combine_in_progress = false
      self
    end


    def eql?(other)
      metrics == other.metrics
    end
    alias :== :eql?
  end
end

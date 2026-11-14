# frozen_string_literal: true

# Note, this class must be Marshal Dumpable
module ScoutApm
  class ExternalServiceMetricSet
    include Enumerable

    attr_reader :metrics # the raw metrics. You probably want #metrics_to_report

    def marshal_dump
      [ @metrics ]
    end

    def marshal_load(array)
      @metrics = array.first
      @context = ScoutApm::Agent.instance.context
      @stat_cache = nil
      @limit = nil
    end

    def initialize(context)
      @context = context

      # A hash of ExternalServiceMetricStats values, keyed by ExternalServiceMetricStats.key
      @metrics = Hash.new
      @stat_cache = nil
    end

    # Need to look this up again if we end up as nil. Which I guess can happen
    # after a Marshal load?
    def context
      @context ||= ScoutApm::Agent.instance.context
    end

    def each
      metrics.each do |_key, external_service_metric_stat|
        yield external_service_metric_stat
      end
    end

    # Looks up a ExternalServiceMetricStats instance in the +@metrics+ hash. Sets the value to +other+ if no key
    # Returns a ExternalServiceMetricStats instance
    def lookup(other)
      metrics[other.key] ||= other
    end

    # Take another set, and merge it with this one
    def combine!(other)
      other.each do |metric|
        self << metric
      end
      self
    end

    # Add a single ExternalServiceMetricStats object to this set.
    #
    # Looks up an existing one under this key and merges, or just saves a new
    # one under the key
    def <<(stat)
      existing_stat = metrics[stat.key]
      if existing_stat
        existing_stat.combine!(stat)
      elsif at_limit?
        # We're full up, can't add any more.
        # Should I log this? It may get super noisy?
      else
        metrics[stat.key] = stat
      end
    end

    # Records a single call measurement in place when the key already exists,
    # avoiding ExternalServiceMetricStats + NumericHistogram + key array
    # allocations for repeated calls in a transaction.
    def record!(domain_name, operation, scope, call_count, call_time)
      by_op = @stat_cache && @stat_cache[scope]
      by_domain = by_op && by_op[operation]
      existing_stat = by_domain && by_domain[domain_name]
      if existing_stat
        existing_stat.record!(call_count, call_time)
        return
      end

      existing_stat = metrics[[domain_name, operation, scope]]
      if existing_stat
        existing_stat.record!(call_count, call_time)
      elsif at_limit?
        return
      else
        existing_stat = ExternalServiceMetricStats.new(domain_name, operation, scope, call_count, call_time)
        metrics[existing_stat.key] = existing_stat
      end

      cache_stat(scope, operation, domain_name, existing_stat)
    end

    def increment_transaction_count!
      metrics.each do |_key, external_service_metric_stat|
        external_service_metric_stat.increment_transaction_count!
      end
    end

    def metrics_to_report
      report_limit = context.config.value('external_service_metric_report_limit')
      if metrics.size > report_limit
        metrics.
          values.
          sort_by {|stat| stat.call_time }.
          reverse.
          take(report_limit)
      else
        metrics.values
      end
    end

    def inspect
      metrics.map {|key, metric|
        "#{key.inspect} - Count: #{metric.call_count}, Total Time: #{"%.2f" % metric.call_time}"
      }.join("\n")
    end

    def at_limit?
      @limit ||= context.config.value('external_service_metric_limit')
      metrics.size >= @limit
    end

    private

    def cache_stat(scope, operation, domain_name, stat)
      cache = (@stat_cache ||= {})
      by_op = (cache[scope] ||= {})
      by_domain = (by_op[operation] ||= {})
      by_domain[domain_name] = stat
    end

  end
end

# frozen_string_literal: true

# Note, this class must be Marshal Dumpable
module ScoutApm
  class DbQueryMetricSet
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

      # A hash of DbQueryMetricStats values, keyed by DbQueryMetricStats.key
      @metrics = Hash.new
      @stat_cache = nil
    end

    # Need to look this up again if we end up as nil. Which I guess can happen
    # after a Marshal load?
    def context
      @context ||= ScoutApm::Agent.instance.context
    end

    def each
      metrics.each do |_key, db_query_metric_stat|
        yield db_query_metric_stat
      end
    end

    # Looks up a DbQueryMetricStats instance in the +@metrics+ hash. Sets the value to +other+ if no key
    # Returns a DbQueryMetricStats instance
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

    # Add a single DbQueryMetricStats object to this set.
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

    # Records a single query measurement in place when the key already exists,
    # avoiding DbQueryMetricStats + NumericHistogram + key array allocations
    # for repeated queries in a transaction.
    def record!(model_name, operation, scope, call_count, call_time, rows_returned)
      by_model = @stat_cache && @stat_cache[scope]
      by_op = by_model && by_model[model_name]
      existing_stat = by_op && by_op[operation]
      if existing_stat
        existing_stat.record!(call_count, call_time, rows_returned)
        return
      end

      existing_stat = metrics[[model_name, operation, scope]]
      if existing_stat
        existing_stat.record!(call_count, call_time, rows_returned)
      elsif at_limit?
        return
      else
        existing_stat = DbQueryMetricStats.new(model_name, operation, scope, call_count, call_time, rows_returned)
        metrics[existing_stat.key] = existing_stat
      end

      cache_stat(scope, model_name, operation, existing_stat)
    end

    def increment_transaction_count!
      metrics.each do |_key, db_query_metric_stat|
        db_query_metric_stat.increment_transaction_count!
      end
    end

    def metrics_to_report
      report_limit = context.config.value('database_metric_report_limit')
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
      @limit ||= context.config.value('database_metric_limit')
      metrics.size >= @limit
    end

    private

    def cache_stat(scope, model_name, operation, stat)
      cache = (@stat_cache ||= {})
      by_model = (cache[scope] ||= {})
      by_op = (by_model[model_name] ||= {})
      by_op[operation] = stat
    end

  end
end

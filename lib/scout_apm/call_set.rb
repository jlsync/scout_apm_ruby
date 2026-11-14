# frozen_string_literal: true

module ScoutApm
  # Encapsulates our logic to determine when a backtrace should be collected.
  class CallSet

    N_PLUS_ONE_MAGIC_NUMBER = 5 # Fetch backtraces on this number of calls to a layer. The caller data is only collected on this call to limit overhead.
    N_PLUS_ONE_TIME_THRESHOLD = 150/1000.0 # Minimum time in seconds before we start performing any work. This is to prevent doing a lot of work on already fast calls.

    attr_reader :call_count

    def initialize
      @items = [] # An array of Layer descriptions that are associated w/a single Layer name (ex: User/find). Note this may contain nil items.
      @grouped_items = nil # lazy grouping as normalizing items and allocating the default-proc Hash can be expensive.
      @call_count = 0
      @captured = false # cached for performance
      @start_time = Time.now
      @past_start_time = false # cached for performance
    end

    def update!(item = nil)
      if @captured # No need to do any work if we've already captured a backtrace.
        return
      end
      @call_count += 1
      @items << item
      if @grouped_items
        @grouped_items[unique_name_for(item)] << item
      end
    end

    # Limit our workload if time across this set of calls is small.
    def past_time_threshold?
      return true if @past_time_threshold # no need to check again once past
      @past_time_threshold = (Time.now-@start_time) >= N_PLUS_ONE_TIME_THRESHOLD
    end

    # We're selective on capturing a backtrace for two reasons:
    # * Grouping ActiveRecord calls requires us to sanitize the SQL. This isn't cheap.
    # * Capturing backtraces isn't cheap.
    def capture_backtrace?
      if !@captured && @call_count >= N_PLUS_ONE_MAGIC_NUMBER && past_time_threshold? && at_magic_number?
        @captured = true
      end
    end

    def at_magic_number?
      grouped_items[unique_name_for(@items.last)].size >= N_PLUS_ONE_MAGIC_NUMBER
    end

    def grouped_items
      @grouped_items ||= begin
        grouped = Hash.new { |h, k| h[k] = [] }
        @items.each { |item| grouped[unique_name_for(item)] << item }
        grouped
      end
    end

    # Determine this items' "hash key"
    def unique_name_for(item)
      item.to_s
    end
  end
end

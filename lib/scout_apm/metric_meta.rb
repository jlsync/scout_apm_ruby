# frozen_string_literal: true

# Contains the meta information associated with a metric. Used to lookup Metrics in to Store's metric_hash.
module ScoutApm
class MetricMeta
  include ScoutApm::BucketNameSplitter

  def initialize(metric_name, options = {})
    @metric_name = metric_name
    @metric_id = nil
    @scope = options[:scope]
    @desc = options[:desc]
    # Allocated lazily: most metrics never carry extra data, and these objects
    # are created once per layer per request.
    @extra = nil
  end

  attr_accessor :metric_id
  attr_accessor :client_id

  attr_reader :metric_name

  # metric_name is also a writer, and #hash / #eql? below depend on it, so any
  # value derived from it has to be dropped when it changes.
  def metric_name=(name)
    @metric_name = name
    @downcased_metric_name = nil
    @bucket_type = nil
    @bucket_name = nil
  end

  attr_reader :scope

  def scope=(scope)
    @scope = scope
    @downcased_scope = nil
  end

  attr_reader :desc

  def desc=(desc)
    @desc = desc
    @downcased_desc = nil
  end

  # An arbitrary bag of extra attributes. Lazily created since the vast
  # majority of MetricMeta objects never carry any.
  def extra
    @extra ||= {}
  end

  def extra=(extra)
    @extra = extra
  end

  # Unsure if type or bucket is a better name.
  def type
    bucket_type
  end

  def name
    bucket_name
  end

  # Memoized: a MetricMeta is used as a Hash key throughout the Store, and the
  # bucket is otherwise re-split out of the metric name on every lookup.
  def bucket_type
    @bucket_type ||= split_metric_name(metric_name).first
  end

  def bucket_name
    @bucket_name ||= split_metric_name(metric_name).last
  end

  # A key metric is the "core" of a request - either the Rails controller reached, or the background Job executed
  def key_metric?
    self.class.key_metric?(metric_name)
  end

  def self.key_metric?(metric_name)
    !!(metric_name =~ /\A(Controller|Job)\//)
  end

  def ==(o)
    self.eql?(o)
  end

  # This should be abstracted to a true accessor ... earned it.
  def backtrace=(bt)
    extra[:backtrace] = bt
  end

  def backtrace
    extra[:backtrace]
  end

  # These are the values used to build the Hash key. They are memoized (the
  # writers above invalidate them) because #hash and #eql? are called on every
  # metric lookup, and re-downcasing a (potentially long) SQL description on
  # each of those calls is expensive.
  def downcased_metric_name
    @downcased_metric_name ||= metric_name.downcase
  end

  def downcased_scope
    @downcased_scope ||= scope.downcase
  end

  def downcased_desc
    @downcased_desc ||= desc.downcase
  end

  def hash
    h = downcased_metric_name.hash
    h ^= downcased_scope.hash unless @scope.nil?
    h ^= downcased_desc.hash unless @desc.nil?
    h
  end

  def eql?(o)
   self.class             == o.class                &&
     downcased_metric_name == o.downcased_metric_name &&
     scope                == o.scope                &&
     client_id            == o.client_id            &&
     desc                 == o.desc
  end

  def as_json
    json_attributes = [:bucket, :name, :desc, :extra, [:scope, :scope_hash]]
    # query, stack_trace
    ScoutApm::AttributeArranger.call(self, json_attributes)
  end
end
end

require 'test_helper'
require File.join(File.dirname(__FILE__), 'stubs')

module ScoutApm
module LayerConverters
class MetricConverterTest < Minitest::Test
  include Stubs

  def test_register_adds_hooks
    mc = MetricConverter.new(agent_context, faux_request, faux_layer_finder, faux_store)
    walker = faux_walker(false)
    walker.expects(:on)
    mc.register_hooks(walker)
  end

  def test_record
    mc = MetricConverter.new(agent_context, faux_request, faux_layer_finder, faux_store)
    faux_store.expects(:track!)
    mc.record!
  end

  # The MetricMeta for scoped layers is cached per layer *type*. A request with
  # several non-scope layer types has to keep reporting each of them
  # separately: caching a single meta for all scoped layers collapsed every
  # type into whichever one was walked first (dropping the others entirely and
  # inflating that first type's call count).
  def test_scoped_metrics_are_kept_separate_per_layer_type
    request = ScoutApm::TrackedRequest.new(agent_context, ScoutApm::FakeStore.new)
    controller = ScoutApm::Layer.new("Controller", "users/index")
    request.start_layer(controller)

    2.times { add_completed_layer(controller, "ActiveRecord", "User/find") }
    3.times { add_completed_layer(controller, "View", "users/_row") }
    add_completed_layer(controller, "HTTP", "api.example.com")

    walker = DepthFirstWalker.new(request.root_layer)
    converter = MetricConverter.new(agent_context, request, FindLayerByType.new(request), ScoutApm::FakeStore.new)
    converter.register_hooks(walker)
    walker.walk
    metrics = converter.record!

    call_counts = {}
    metrics.each { |meta, stat| call_counts[[meta.metric_name, meta.scope]] = stat.call_count }

    assert_equal 1, call_counts[["Controller/users/index", nil]]
    assert_equal 2, call_counts[["ActiveRecord", "Controller/users/index"]]
    assert_equal 3, call_counts[["View", "Controller/users/index"]]
    assert_equal 1, call_counts[["HTTP", "Controller/users/index"]]
  end

  def test_job_converter_keeps_scoped_metrics_separate_per_type
    request = ScoutApm::TrackedRequest.new(agent_context, ScoutApm::FakeStore.new)
    queue = ScoutApm::Layer.new("Queue", "default")
    request.start_layer(queue)
    job = ScoutApm::Layer.new("Job", "HardWorker")
    request.start_layer(job)
    2.times { add_completed_layer(job, "ActiveRecord", "User/find") }
    3.times { add_completed_layer(job, "HTTP", "api.example.com") }
    request.stop_layer
    request.stop_layer

    walker = DepthFirstWalker.new(request.root_layer)
    converter = JobConverter.new(agent_context, request, FindLayerByType.new(request), ScoutApm::FakeStore.new)
    converter.register_hooks(walker)
    walker.walk
    job_record = converter.record!

    call_counts = {}
    job_record.metrics.each { |meta, stat| call_counts[[meta.metric_name, meta.scope]] = stat.call_count }
    assert_equal 2, call_counts[["ActiveRecord/all", "Job/HardWorker"]]
    assert_equal 3, call_counts[["HTTP/all", "Job/HardWorker"]]
    assert_equal 1, call_counts[["Latency/all", "Job/HardWorker"]]
  end

  def test_slow_request_converter_subscoping_and_trace_spans
    ctx = ScoutApm::AgentContext.new
    ctx.config = make_fake_config('timeline_traces' => true)
    request = ScoutApm::TrackedRequest.new(ctx, ScoutApm::FakeStore.new)
    controller = ScoutApm::Layer.new("Controller", "users/index")
    request.start_layer(controller)
    view = ScoutApm::Layer.new("View", "users/index.html.erb")
    view.subscopable!
    request.start_layer(view)
    add_completed_layer(view, "ActiveRecord", "User/find")
    request.stop_layer
    request.stop_layer

    finder = FindLayerByType.new(request)
    conv = SlowRequestConverter.new(ctx, request, finder, ScoutApm::FakeStore.new)
    slow_tx = conv.call

    ar_keys = slow_tx.metrics.keys.select { |m| m.metric_name.start_with?("ActiveRecord") }
    assert ar_keys.any? { |m| m.scope == "View/users/index.html.erb" }

    spans = slow_tx.span_trace.spans
    assert_equal 3, spans.size
    assert_equal "", spans[0].parent_id
    assert_equal spans[0].span_id, spans[1].parent_id
    assert_equal spans[1].span_id, spans[2].parent_id
  end

  def test_database_converter_handles_malformed_and_standard_layer_names
    ctx = ScoutApm::AgentContext.new
    request = ScoutApm::TrackedRequest.new(ctx, ScoutApm::FakeStore.new)
    controller = ScoutApm::Layer.new("Controller", "users/index")
    request.start_layer(controller)

    ["User/find", "/", "User//find", "/custom", "User/"].each do |name|
      add_completed_layer(controller, "ActiveRecord", name)
    end
    request.stop_layer

    walker = DepthFirstWalker.new(request.root_layer)
    conv = DatabaseConverter.new(ctx, request, FindLayerByType.new(request), ScoutApm::FakeStore.new)
    conv.register_hooks(walker)
    walker.walk
    set = conv.instance_variable_get(:@db_query_metric_set)

    keys = set.metrics.keys.map { |m, op, _s| [m, op] }.sort
    expected = [["", "custom"], ["SQL", "other"], ["User", ""], ["User", "find"], ["User", "other"]]
    assert_equal expected, keys
  end

  private

  def add_completed_layer(parent, type, name)
    layer = ScoutApm::Layer.new(type, name)
    layer.record_stop_time!
    layer.record_allocations!
    parent.add_child(layer)
    layer
  end
end
end
end

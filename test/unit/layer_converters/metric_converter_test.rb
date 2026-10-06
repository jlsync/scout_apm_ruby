require 'test_helper'
require File.join(File.dirname(__FILE__), 'stubs')

module ScoutApm
module LayerConverters
class MetricConverterTest < Minitest::Test
  include Stubs

  def test_register_adds_hooks
    mc = MetricConverter.new(agent_context, faux_request, faux_layer_finder, faux_store)
    faux_walker.expects(:on)
    mc.register_hooks(faux_walker)
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

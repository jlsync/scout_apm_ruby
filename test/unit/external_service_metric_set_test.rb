require 'test_helper'

require 'scout_apm/external_service_metric_set'

module ScoutApm
class ExternalServiceMetricSetTest < Minitest::Test
  def test_hard_limit
    config = make_fake_config(
      'external_service_metric_limit' => 5, # The hard limit on db metrics
      'external_service_metric_report_limit' => 2
    )
    context = ScoutApm::AgentContext.new().tap{|c| c.config = config }
    set = ExternalServiceMetricSet.new(context)

    set << fake_stat("a", 10)
    set << fake_stat("b", 20)
    set << fake_stat("c", 30)
    set << fake_stat("d", 40)
    set << fake_stat("e", 50)
    set << fake_stat("f", 60)

    assert_equal 5, set.metrics.size
  end

  def test_report_limit
    config = make_fake_config(
      'external_service_metric_limit' => 50, # much larger max, uninterested in hitting it.
      'external_service_metric_report_limit' => 2
    )
    context = ScoutApm::AgentContext.new().tap{|c| c.config = config }
    set = ExternalServiceMetricSet.new(context)
    set << fake_stat("a", 10)
    set << fake_stat("b", 20)
    set << fake_stat("c", 30)
    set << fake_stat("d", 40)
    set << fake_stat("e", 50)
    set << fake_stat("f", 60)

    assert_equal 2, set.metrics_to_report.size
    assert_equal ["f","e"], set.metrics_to_report.map{|m| m.key}
  end

  def test_combine
    config = make_fake_config(
      'external_service_metric_limit' => 5, # The hard limit on db metrics
      'external_service_metric_report_limit' => 2
    )
    context = ScoutApm::AgentContext.new().tap{|c| c.config = config }
    set1 = ExternalServiceMetricSet.new(context)
    set1 << fake_stat("a", 10)
    set1 << fake_stat("b", 20)
    set2 = ExternalServiceMetricSet.new(context)
    set2 << fake_stat("c", 10)
    set2 << fake_stat("d", 20)

    combined = set1.combine!(set2)
    assert_equal ["a", "b", "c", "d"], combined.metrics.map{|_k, m| m.key}.sort
  end

  def test_record_in_place_matches_combine_and_respects_limit
    config = make_fake_config(
      'external_service_metric_limit' => 2,
      'external_service_metric_report_limit' => 10
    )
    context = ScoutApm::AgentContext.new.tap { |c| c.config = config }

    recorded = ExternalServiceMetricSet.new(context)
    recorded.record!("api.example.com", "all", "Controller/users/index", 1, 0.25)
    recorded.record!("api.example.com", "all", "Controller/users/index", 1, 0.75)
    recorded.record!("auth.example.com", "all", "Controller/users/index", 1, 0.50)
    # Over limit: new key ignored, existing key still updated in place.
    recorded.record!("cdn.example.com", "all", "Controller/users/index", 1, 0.90)
    recorded.record!("api.example.com", "all", "Controller/users/index", 1, 0.10)

    combined = ExternalServiceMetricSet.new(context)
    combined << ExternalServiceMetricStats.new("api.example.com", "all", "Controller/users/index", 1, 0.25)
    combined << ExternalServiceMetricStats.new("api.example.com", "all", "Controller/users/index", 1, 0.75)
    combined << ExternalServiceMetricStats.new("auth.example.com", "all", "Controller/users/index", 1, 0.50)
    combined << ExternalServiceMetricStats.new("cdn.example.com", "all", "Controller/users/index", 1, 0.90)
    combined << ExternalServiceMetricStats.new("api.example.com", "all", "Controller/users/index", 1, 0.10)

    assert_equal 2, recorded.metrics.size
    api_rec = recorded.metrics[["api.example.com", "all", "Controller/users/index"]]
    api_exp = combined.metrics[["api.example.com", "all", "Controller/users/index"]]
    assert_equal api_exp.call_count, api_rec.call_count
    assert_in_delta api_exp.call_time, api_rec.call_time, 1e-9
    assert_in_delta api_exp.min_call_time, api_rec.min_call_time, 1e-9
    assert_in_delta api_exp.max_call_time, api_rec.max_call_time, 1e-9
    assert_equal api_exp.histogram.as_json, api_rec.histogram.as_json

    loaded = Marshal.load(Marshal.dump(recorded))
    loaded.record!("api.example.com", "all", "Controller/users/index", 1, 0.40)
    assert_equal 4, loaded.metrics[["api.example.com", "all", "Controller/users/index"]].call_count
  end

  def fake_stat(key, call_time)
    OpenStruct.new(
      :key => key,
      :call_time => call_time
    )
  end
end
end

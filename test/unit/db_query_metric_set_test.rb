require 'test_helper'

require 'scout_apm/db_query_metric_set'

module ScoutApm
class DbQueryMetricSetTest < Minitest::Test
  def test_hard_limit
    config = make_fake_config(
      'database_metric_limit' => 5, # The hard limit on db metrics
      'database_metric_report_limit' => 2
    )
    context = ScoutApm::AgentContext.new().tap{|c| c.config = config }
    set = DbQueryMetricSet.new(context)

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
      'database_metric_limit' => 50, # much larger max, uninterested in hitting it.
      'database_metric_report_limit' => 2
    )
    context = ScoutApm::AgentContext.new().tap{|c| c.config = config }
    set = DbQueryMetricSet.new(context)
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
      'database_metric_limit' => 5, # The hard limit on db metrics
      'database_metric_report_limit' => 2
    )
    context = ScoutApm::AgentContext.new().tap{|c| c.config = config }
    set1 = DbQueryMetricSet.new(context)
    set1 << fake_stat("a", 10)
    set1 << fake_stat("b", 20)
    set2 = DbQueryMetricSet.new(context)
    set2 << fake_stat("c", 10)
    set2 << fake_stat("d", 20)

    combined = set1.combine!(set2)
    assert_equal ["a", "b", "c", "d"], combined.metrics.map{|_k, m| m.key}.sort
  end

  def test_record_in_place_matches_combine_and_respects_limit
    config = make_fake_config(
      'database_metric_limit' => 2,
      'database_metric_report_limit' => 10
    )
    context = ScoutApm::AgentContext.new.tap { |c| c.config = config }

    recorded = DbQueryMetricSet.new(context)
    recorded.record!("User", "find", "Controller/users/index", 1, 0.25, 1)
    recorded.record!("User", "find", "Controller/users/index", 1, 0.75, 4)
    recorded.record!("Post", "find", "Controller/users/index", 1, 0.50, 2)
    # Over limit: new key ignored, existing key still updated in place.
    recorded.record!("Comment", "find", "Controller/users/index", 1, 0.90, 3)
    recorded.record!("User", "find", "Controller/users/index", 1, 0.10, 0)

    combined = DbQueryMetricSet.new(context)
    combined << DbQueryMetricStats.new("User", "find", "Controller/users/index", 1, 0.25, 1)
    combined << DbQueryMetricStats.new("User", "find", "Controller/users/index", 1, 0.75, 4)
    combined << DbQueryMetricStats.new("Post", "find", "Controller/users/index", 1, 0.50, 2)
    combined << DbQueryMetricStats.new("Comment", "find", "Controller/users/index", 1, 0.90, 3)
    combined << DbQueryMetricStats.new("User", "find", "Controller/users/index", 1, 0.10, 0)

    assert_equal 2, recorded.metrics.size
    user_rec = recorded.metrics[["User", "find", "Controller/users/index"]]
    user_exp = combined.metrics[["User", "find", "Controller/users/index"]]
    assert_equal user_exp.call_count, user_rec.call_count
    assert_in_delta user_exp.call_time, user_rec.call_time, 1e-9
    assert_in_delta user_exp.min_call_time, user_rec.min_call_time, 1e-9
    assert_in_delta user_exp.max_call_time, user_rec.max_call_time, 1e-9
    assert_equal user_exp.rows_returned, user_rec.rows_returned
    assert_equal user_exp.min_rows_returned, user_rec.min_rows_returned
    assert_equal user_exp.max_rows_returned, user_rec.max_rows_returned
    assert_equal user_exp.histogram.as_json, user_rec.histogram.as_json

    loaded = Marshal.load(Marshal.dump(recorded))
    loaded.record!("User", "find", "Controller/users/index", 1, 0.40, 2)
    assert_equal 4, loaded.metrics[["User", "find", "Controller/users/index"]].call_count
  end

  def fake_stat(key, call_time)
    OpenStruct.new(
      :key => key,
      :call_time => call_time
    )
  end
end
end

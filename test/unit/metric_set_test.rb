require 'test_helper'

require 'scout_apm/metric_set'

module ScoutApm
  class MetricSetTest < Minitest::Test
    def setup
      @metric_set = ScoutApm::MetricSet.new
    end

    def test_absorb_one_passthrough_metric
      @metric_set.absorb(make_fake_stat("Controller/Foo", 1))

      assert_equal 1, @metric_set.metrics.length
      assert_equal "Controller/Foo", @metric_set.metrics.first.first.metric_name
    end

    def test_absorb_one_aggregate_metric
      @metric_set.absorb(make_fake_stat("ActiveRecord/Foo", 1))

      assert_equal 1, @metric_set.metrics.length
      assert_equal "ActiveRecord/all", @metric_set.metrics.first.first.metric_name
    end

    def test_absorb_many_aggregate_metric
      @metric_set.absorb(make_fake_stat("ActiveRecord/Foo", 1))
      @metric_set.absorb(make_fake_stat("ActiveRecord/Bar", 1))
      @metric_set.absorb(make_fake_stat("ActiveRecord/Baz", 1))
      @metric_set.absorb(make_fake_stat("HTTP/Get", 1))
      @metric_set.absorb(make_fake_stat("HTTP/Post", 1))

      metrics = @metric_set.metrics.to_a.sort_by { |m| m.first.metric_name }
      assert_equal 2, metrics.length
      assert_equal "ActiveRecord/all", metrics[0][0].metric_name
      assert_equal "HTTP/all", metrics[1][0].metric_name
      assert_equal 3, metrics[0][1].call_count
      assert_equal 2, metrics[1][1].call_count
    end

    def test_absorb_one_error
      @metric_set.absorb(make_fake_stat("Errors/Controller/public/index", 1))

      metrics = @metric_set.metrics.to_a.sort_by { |m| m.first.metric_name }
      assert_equal 2, metrics.length
      assert_equal "Errors/Controller/public/index", metrics[0].first.metric_name
      assert_equal "Errors/Request",  metrics[1].first.metric_name
    end

    def test_absorb_many_metrics
      @metric_set.absorb_all([
        make_fake_stat("ActiveRecord/Foo", 1),
        make_fake_stat("Controller/Bar", 1)
      ])

      metrics = @metric_set.metrics.to_a.sort_by { |m| m.first.metric_name }
      assert_equal 2, metrics.length
      assert_equal "ActiveRecord/all", metrics[0].first.metric_name
      assert_equal "Controller/Bar",  metrics[1].first.metric_name
    end

    def test_combine
      @other_set = ScoutApm::MetricSet.new

      @metric_set.absorb_all([
        make_fake_stat("ActiveRecord/Foo", 1),
        make_fake_stat("Controller/Bar", 1),
        make_fake_stat("Errors/Controller/public/index", 1),
      ])

      @other_set.absorb_all([
        make_fake_stat("ActiveRecord/Foo", 1),
        make_fake_stat("Controller/Bar", 1),
        make_fake_stat("Errors/Controller/public/index", 1),
      ])

      @metric_set.combine!(@other_set)

      metrics = @metric_set.metrics.to_a.sort_by { |m| m.first.metric_name }
      assert_equal 4, metrics.length
      assert_equal "ActiveRecord/all", metrics[0][0].metric_name
      assert_equal "Controller/Bar",  metrics[1][0].metric_name
      assert_equal "Errors/Controller/public/index", metrics[2][0].metric_name
      assert_equal "Errors/Request",  metrics[3][0].metric_name

      assert_equal 2, metrics[0][1].call_count
      assert_equal 2, metrics[1][1].call_count
      assert_equal 2, metrics[2][1].call_count
      assert_equal 2, metrics[3][1].call_count
    end

    def test_absorb_all_hash_and_marshal_roundtrip
      input = {}
      3.times do |i|
        meta = MetricMeta.new("ActiveRecord/Model#{i}/find", :scope => "Controller/users/index")
        stat = MetricStats.new(true)
        stat.update!(0.1)
        input[meta] = stat
      end
      err_meta = MetricMeta.new("Errors/Controller/users/index", :scope => "Controller/users/index")
      err_stat = MetricStats.new(true)
      err_stat.update!(1)
      input[err_meta] = err_stat

      @metric_set.absorb_all(input)
      assert_equal 3, @metric_set.metrics[MetricMeta.new("ActiveRecord/all", :scope => "Controller/users/index")].call_count
      assert_equal 1, @metric_set.metrics[MetricMeta.new("Errors/Request", :scope => "Controller/users/index")].call_count

      loaded = Marshal.load(Marshal.dump(@metric_set))
      assert_equal @metric_set.metrics.keys.sort_by(&:metric_name),
        loaded.metrics.keys.sort_by(&:metric_name)
      assert_equal 3, loaded.metrics[MetricMeta.new("ActiveRecord/all", :scope => "Controller/users/index")].call_count
      loaded.absorb_all(input)
      assert_equal 6, loaded.metrics[MetricMeta.new("ActiveRecord/all", :scope => "Controller/users/index")].call_count
    end

    ############################################################
    # Test helper functions
    ############################################################
    def make_fake_stat(name, count)
      meta = MetricMeta.new(name)
      stat = MetricStats.new
      stat.update!(count)
      [meta, stat]
    end
  end
end

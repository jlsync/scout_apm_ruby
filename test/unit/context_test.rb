require 'test_helper'

require 'scout_apm/context'

class ContextText < Minitest::Test
  def test_ignore_nil_value
    context = ScoutApm::Context.new(ScoutApm::AgentContext.new)
    assert hash = context.add(:nil_key => nil, :org => 'org')
    assert_equal ({:org => 'org'}), hash
  end

  def test_ignore_nil_key
    context = ScoutApm::Context.new(ScoutApm::AgentContext.new)
    assert hash = context.add(nil => nil, :org => 'org')
    assert_equal ({:org => 'org'}), hash
  end

  def test_ignore_unsupported_value_type
    context = ScoutApm::Context.new(ScoutApm::AgentContext.new)
    assert hash = context.add(:array => [1,2,3,4], :org => 'org')
    assert_equal ({:org => 'org'}), hash
  end

  def test_ignore_unsupported_key_type
    context = ScoutApm::Context.new(ScoutApm::AgentContext.new)
    assert hash = context.add([1,2,3,4] => 'hey', :org => 'org')
    assert_equal ({:org => 'org'}), hash
  end

  def test_returns_nil_when_no_valid_keys_and_validates_user_context
    context = ScoutApm::Context.new(ScoutApm::AgentContext.new)
    assert_nil context.add(:nil_key => nil, "bad key" => "v")
    assert_equal ({:id => 42}), context.add_user(:id => 42, :bad => [1])
    assert_equal ({:user => {:id => 42}}), context.to_hash
    assert_equal ({"user_id" => 42}), context.to_flat_hash
  end
end


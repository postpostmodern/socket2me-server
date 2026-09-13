# frozen_string_literal: true

require "test_helper"
require "async"
require "request_broker"

class RequestBrokerTest < Minitest::Test
  def test_delivers_response_to_the_waiter
    broker = Socket2Me::RequestBroker.new
    Sync do |task|
      broker.register("abc")
      task.async { broker.deliver_response("abc", { "status" => 200 }) }
      assert_equal({ "status" => 200 }, broker.await_response("abc", 5))
    end
  end

  def test_resolution_before_wait_is_not_lost
    broker = Socket2Me::RequestBroker.new
    Sync do
      broker.register("early")
      # deliver_response happens before anyone awaits; the promise stores it.
      broker.deliver_response("early", { "status" => 201 })
      assert_equal({ "status" => 201 }, broker.await_response("early", 5))
    end
  end

  def test_times_out_without_a_response
    broker = Socket2Me::RequestBroker.new
    Sync do
      broker.register("slow")
      assert_nil broker.await_response("slow", 0.05)
    end
  end

  def test_unknown_id_returns_nil
    broker = Socket2Me::RequestBroker.new
    Sync do
      assert_nil broker.await_response("missing", 0.05)
    end
  end

  def test_deliver_to_unknown_id_is_false
    broker = Socket2Me::RequestBroker.new
    assert_equal false, broker.deliver_response("missing", {})
  end

  def test_entry_is_cleaned_up_after_await
    broker = Socket2Me::RequestBroker.new
    Sync do
      broker.register("once")
      broker.deliver_response("once", { "ok" => true })
      broker.await_response("once", 1)
      # A second delivery finds no entry, proving the id was removed.
      assert_equal false, broker.deliver_response("once", { "ok" => true })
    end
  end
end

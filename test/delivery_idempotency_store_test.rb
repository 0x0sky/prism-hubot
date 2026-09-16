# © 2026 aiaiaiai · aiaiaiai.org

require_relative "test_helper"

class DeliveryIdempotencyStoreTest < Minitest::Test
  def test_unknown_key_returns_nil
    Dir.mktmpdir do |directory|
      store = PrismHubot::DeliveryIdempotencyStore.new(directory: directory, ttl_seconds: 900)

      assert_nil store.fetch(idempotency_key: "never-stored")
    end
  end

  def test_stored_key_is_recalled
    Dir.mktmpdir do |directory|
      store = PrismHubot::DeliveryIdempotencyStore.new(directory: directory, ttl_seconds: 900)

      store.store(idempotency_key: "chunk-1", provider_message_id: 4242)

      assert_equal 4242, store.fetch(idempotency_key: "chunk-1")
    end
  end

  def test_entry_survives_store_recreation
    Dir.mktmpdir do |directory|
      clock = 1_000
      first = PrismHubot::DeliveryIdempotencyStore.new(directory: directory, ttl_seconds: 900, clock: -> { clock })
      first.store(idempotency_key: "chunk-1", provider_message_id: 7)

      second = PrismHubot::DeliveryIdempotencyStore.new(directory: directory, ttl_seconds: 900, clock: -> { clock })

      assert_equal 7, second.fetch(idempotency_key: "chunk-1")
    end
  end

  def test_expired_entry_is_dropped_and_removed
    Dir.mktmpdir do |directory|
      clock = 1_000
      store = PrismHubot::DeliveryIdempotencyStore.new(directory: directory, ttl_seconds: 10, clock: -> { clock })
      store.store(idempotency_key: "chunk-1", provider_message_id: 7)

      clock = 1_011

      assert_nil store.fetch(idempotency_key: "chunk-1")
      assert_empty Dir.children(directory)
    end
  end

  def test_different_keys_do_not_collide
    Dir.mktmpdir do |directory|
      store = PrismHubot::DeliveryIdempotencyStore.new(directory: directory, ttl_seconds: 900)

      store.store(idempotency_key: "chunk-1", provider_message_id: 1)
      store.store(idempotency_key: "chunk-2", provider_message_id: 2)

      assert_equal 1, store.fetch(idempotency_key: "chunk-1")
      assert_equal 2, store.fetch(idempotency_key: "chunk-2")
    end
  end

  def test_rejects_a_non_positive_ttl
    Dir.mktmpdir do |directory|
      assert_raises(ArgumentError) do
        PrismHubot::DeliveryIdempotencyStore.new(directory: directory, ttl_seconds: 0)
      end
    end
  end
end

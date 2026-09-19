# © 2026 aiaiaiai · aiaiaiai.org

require_relative "test_helper"

class DeliveryIdempotencyStoreTest < Minitest::Test
  def test_first_reservation_for_a_key_is_reserved
    Dir.mktmpdir do |directory|
      store = build_store(directory)

      reservation = store.reserve(idempotency_key: "chunk-1")

      assert reservation.reserved?
      assert_nil reservation.provider_message_id
    end
  end

  def test_completed_reservation_is_replayed_without_re_reserving
    Dir.mktmpdir do |directory|
      store = build_store(directory)
      store.reserve(idempotency_key: "chunk-1")
      store.complete!(idempotency_key: "chunk-1", provider_message_id: 42)

      reservation = store.reserve(idempotency_key: "chunk-1")

      assert reservation.completed?
      assert_equal 42, reservation.provider_message_id
    end
  end

  def test_completed_result_survives_store_recreation
    Dir.mktmpdir do |directory|
      clock = 1_000
      first = build_store(directory, clock: -> { clock })
      first.reserve(idempotency_key: "chunk-1")
      first.complete!(idempotency_key: "chunk-1", provider_message_id: 7)

      second = build_store(directory, clock: -> { clock })
      reservation = second.reserve(idempotency_key: "chunk-1")

      assert reservation.completed?
      assert_equal 7, reservation.provider_message_id
    end
  end

  # The concurrency case the review flagged: a second attempt for the same
  # key while the first is still in flight must not be allowed to also call
  # Telegram — it has to see `in_progress?`, not a fresh reservation.
  def test_reserving_an_in_flight_key_reports_in_progress
    Dir.mktmpdir do |directory|
      store = build_store(directory)
      store.reserve(idempotency_key: "chunk-1")

      reservation = store.reserve(idempotency_key: "chunk-1")

      refute reservation.reserved?
      assert reservation.in_progress?
    end
  end

  def test_a_stale_reservation_can_be_stolen_and_reserved_again
    Dir.mktmpdir do |directory|
      clock = 1_000
      store = build_store(directory, reservation_ttl_seconds: 10, clock: -> { clock })
      store.reserve(idempotency_key: "chunk-1")

      clock = 1_011

      reservation = store.reserve(idempotency_key: "chunk-1")

      assert reservation.reserved?
    end
  end

  def test_a_completed_record_expires_and_is_reservable_again
    Dir.mktmpdir do |directory|
      clock = 1_000
      store = build_store(directory, ttl_seconds: 10, clock: -> { clock })
      store.reserve(idempotency_key: "chunk-1")
      store.complete!(idempotency_key: "chunk-1", provider_message_id: 7)

      clock = 1_011

      reservation = store.reserve(idempotency_key: "chunk-1")

      assert reservation.reserved?
    end
  end

  def test_release_lets_an_immediate_retry_through_without_waiting_out_the_ttl
    Dir.mktmpdir do |directory|
      store = build_store(directory, reservation_ttl_seconds: 900)
      store.reserve(idempotency_key: "chunk-1")

      store.release(idempotency_key: "chunk-1")

      assert store.reserve(idempotency_key: "chunk-1").reserved?
    end
  end

  def test_release_never_touches_a_completed_record
    Dir.mktmpdir do |directory|
      store = build_store(directory)
      store.reserve(idempotency_key: "chunk-1")
      store.complete!(idempotency_key: "chunk-1", provider_message_id: 7)

      store.release(idempotency_key: "chunk-1")

      reservation = store.reserve(idempotency_key: "chunk-1")
      assert reservation.completed?
      assert_equal 7, reservation.provider_message_id
    end
  end

  def test_release_of_an_unknown_key_is_a_safe_no_op
    Dir.mktmpdir do |directory|
      store = build_store(directory)

      store.release(idempotency_key: "never-reserved")
    end
  end

  def test_different_keys_do_not_collide
    Dir.mktmpdir do |directory|
      store = build_store(directory)
      store.reserve(idempotency_key: "chunk-1")
      store.reserve(idempotency_key: "chunk-2")
      store.complete!(idempotency_key: "chunk-1", provider_message_id: 1)
      store.complete!(idempotency_key: "chunk-2", provider_message_id: 2)

      assert_equal 1, store.reserve(idempotency_key: "chunk-1").provider_message_id
      assert_equal 2, store.reserve(idempotency_key: "chunk-2").provider_message_id
    end
  end

  def test_rejects_a_non_positive_ttl
    Dir.mktmpdir do |directory|
      assert_raises(ArgumentError) { build_store(directory, ttl_seconds: 0) }
    end
  end

  def test_rejects_a_non_positive_reservation_ttl
    Dir.mktmpdir do |directory|
      assert_raises(ArgumentError) { build_store(directory, reservation_ttl_seconds: 0) }
    end
  end

  private

  def build_store(directory, ttl_seconds: 900, reservation_ttl_seconds: 30, clock: -> { Time.now.to_i })
    PrismHubot::DeliveryIdempotencyStore.new(
      directory: directory,
      ttl_seconds: ttl_seconds,
      reservation_ttl_seconds: reservation_ttl_seconds,
      clock: clock
    )
  end
end

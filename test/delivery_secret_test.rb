# © 2026 aiaiaiai · aiaiaiai.org

require_relative "test_helper"

class DeliverySecretTest < Minitest::Test
  def test_matching_secret_is_valid
    secret = PrismHubot::DeliverySecret.new("a" * 32)

    assert secret.valid?("a" * 32)
  end

  def test_mismatched_secret_is_invalid
    secret = PrismHubot::DeliverySecret.new("a" * 32)

    refute secret.valid?("b" * 32)
  end

  def test_non_string_candidate_is_invalid
    secret = PrismHubot::DeliverySecret.new("a" * 32)

    refute secret.valid?(nil)
    refute secret.valid?(12345)
  end

  def test_rejects_a_secret_shorter_than_the_minimum
    error = assert_raises(PrismBot::ConfigurationError) do
      PrismHubot::DeliverySecret.new("short")
    end

    assert_equal "prism_hubot.delivery_secret.invalid", error.code
  end
end

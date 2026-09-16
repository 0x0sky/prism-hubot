# © 2026 aiaiaiai · aiaiaiai.org

require_relative "test_helper"

class DeliveryConfigurationTest < Minitest::Test
  SECRET = "s" * 32

  def test_absent_secret_disables_the_feature
    assert_nil PrismHubot::DeliveryConfiguration.from_environment({})
    assert_nil PrismHubot::DeliveryConfiguration.from_environment("PRISM_BOT_DELIVERY_SECRET" => "")
    assert_nil PrismHubot::DeliveryConfiguration.from_environment("PRISM_BOT_DELIVERY_SECRET" => "   ")
  end

  def test_defaults_apply_when_only_the_secret_is_set
    configuration = PrismHubot::DeliveryConfiguration.from_environment("PRISM_BOT_DELIVERY_SECRET" => SECRET)

    assert configuration.secret.valid?(SECRET)
    assert_equal File.expand_path("var/delivery-idempotency"), configuration.idempotency_directory
    assert_equal 86_400, configuration.idempotency_ttl_seconds
    assert_equal 65_536, configuration.max_body_bytes
  end

  def test_overrides_are_honoured
    configuration = PrismHubot::DeliveryConfiguration.from_environment(
      "PRISM_BOT_DELIVERY_SECRET" => SECRET,
      "PRISM_HUBOT_DELIVERY_IDEMPOTENCY_DIR" => "tmp/custom-dir",
      "PRISM_HUBOT_DELIVERY_IDEMPOTENCY_TTL_SECONDS" => "60",
      "PRISM_HUBOT_DELIVERY_MAX_BODY_BYTES" => "2048"
    )

    assert_equal File.expand_path("tmp/custom-dir"), configuration.idempotency_directory
    assert_equal 60, configuration.idempotency_ttl_seconds
    assert_equal 2048, configuration.max_body_bytes
  end

  def test_rejects_an_invalid_ttl
    error = assert_raises(PrismBot::ConfigurationError) do
      PrismHubot::DeliveryConfiguration.from_environment(
        "PRISM_BOT_DELIVERY_SECRET" => SECRET,
        "PRISM_HUBOT_DELIVERY_IDEMPOTENCY_TTL_SECONDS" => "0"
      )
    end

    assert_equal "prism_hubot.configuration.integer.invalid", error.code
  end

  def test_rejects_an_invalid_max_body_bytes
    assert_raises(PrismBot::ConfigurationError) do
      PrismHubot::DeliveryConfiguration.from_environment(
        "PRISM_BOT_DELIVERY_SECRET" => SECRET,
        "PRISM_HUBOT_DELIVERY_MAX_BODY_BYTES" => "not-a-number"
      )
    end
  end

  def test_rejects_a_secret_that_is_too_short
    assert_raises(PrismBot::ConfigurationError) do
      PrismHubot::DeliveryConfiguration.from_environment("PRISM_BOT_DELIVERY_SECRET" => "short")
    end
  end
end

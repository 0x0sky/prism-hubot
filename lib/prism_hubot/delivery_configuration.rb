# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  # Configuration for the optional `/api/v1/delivery` receiver. Unlike
  # `PrismHubot::Configuration`, this is not required: `from_environment`
  # returns nil when `PRISM_BOT_DELIVERY_SECRET` is absent, and `config.ru`
  # mounts no delivery route at all in that case. Existing deployments that
  # have never heard of Prism Hub's delivery worker keep booting unchanged.
  class DeliveryConfiguration
    DEFAULT_IDEMPOTENCY_DIRECTORY = "var/delivery-idempotency".freeze
    DEFAULT_IDEMPOTENCY_TTL_SECONDS = 86_400
    # How long a delivery attempt may hold its reservation before a retry may
    # steal it. Only needs to outlast a genuine in-flight attempt to Telegram
    # (bounded by NetHttpTransport's open + read timeouts, seconds not
    # minutes); see DeliveryIdempotencyStore for what a crash inside that
    # window still costs.
    DEFAULT_RESERVATION_TTL_SECONDS = 30
    DEFAULT_MAX_BODY_BYTES = 65_536

    attr_reader :secret, :idempotency_directory, :idempotency_ttl_seconds,
      :reservation_ttl_seconds, :max_body_bytes

    def self.from_environment(environment)
      raw_secret = String(environment["PRISM_BOT_DELIVERY_SECRET"]).strip
      return nil if raw_secret.empty?

      new(
        secret: raw_secret,
        idempotency_directory: environment.fetch(
          "PRISM_HUBOT_DELIVERY_IDEMPOTENCY_DIR",
          DEFAULT_IDEMPOTENCY_DIRECTORY
        ),
        idempotency_ttl_seconds: environment.fetch(
          "PRISM_HUBOT_DELIVERY_IDEMPOTENCY_TTL_SECONDS",
          DEFAULT_IDEMPOTENCY_TTL_SECONDS.to_s
        ),
        reservation_ttl_seconds: environment.fetch(
          "PRISM_HUBOT_DELIVERY_RESERVATION_TTL_SECONDS",
          DEFAULT_RESERVATION_TTL_SECONDS.to_s
        ),
        max_body_bytes: environment.fetch(
          "PRISM_HUBOT_DELIVERY_MAX_BODY_BYTES",
          DEFAULT_MAX_BODY_BYTES.to_s
        )
      )
    end

    def initialize(secret:, idempotency_directory:, idempotency_ttl_seconds:, reservation_ttl_seconds:, max_body_bytes:)
      @secret = DeliverySecret.new(secret)
      @idempotency_directory = resolve_directory(idempotency_directory)
      @idempotency_ttl_seconds = positive_integer(
        idempotency_ttl_seconds,
        "PRISM_HUBOT_DELIVERY_IDEMPOTENCY_TTL_SECONDS"
      )
      @reservation_ttl_seconds = positive_integer(
        reservation_ttl_seconds,
        "PRISM_HUBOT_DELIVERY_RESERVATION_TTL_SECONDS"
      )
      @max_body_bytes = positive_integer(max_body_bytes, "PRISM_HUBOT_DELIVERY_MAX_BODY_BYTES")
      freeze
    end

    private

    def resolve_directory(value)
      directory = String(value).strip
      if directory.empty?
        raise PrismBot::ConfigurationError.new(
          "prism_hubot.delivery.directory.invalid",
          "PRISM_HUBOT_DELIVERY_IDEMPOTENCY_DIR must not be empty"
        )
      end

      File.expand_path(directory).freeze
    end

    def positive_integer(value, name)
      integer = Integer(value)
      return integer if integer.positive?

      raise ArgumentError
    rescue ArgumentError, TypeError
      raise PrismBot::ConfigurationError.new(
        "prism_hubot.configuration.integer.invalid",
        "#{name} must be a positive integer"
      )
    end
  end
end

# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  # Authenticates `POST /api/v1/delivery`: the boundary where Prism Hub's
  # delivery worker (`HttpBotDeliveryGateway`) pushes a rendered chunk for this
  # client to relay to Telegram. This is a distinct trust boundary from
  # `PrismBot::Channels::Telegram::WebhookSecret` — that one authenticates
  # Telegram calling in; this one authenticates Hub calling in — so it is its
  # own secret, never reused between the two directions.
  class DeliverySecret
    MIN_LENGTH = 16
    MAX_LENGTH = 4_096

    def initialize(value)
      @value = String(value).dup.freeze
      return if (MIN_LENGTH..MAX_LENGTH).cover?(@value.length)

      raise PrismBot::ConfigurationError.new(
        "prism_hubot.delivery_secret.invalid",
        "PRISM_BOT_DELIVERY_SECRET must contain #{MIN_LENGTH} to #{MAX_LENGTH} characters"
      )
    end

    def valid?(candidate)
      candidate.is_a?(String) && Rack::Utils.secure_compare(candidate, @value)
    end
  end
end

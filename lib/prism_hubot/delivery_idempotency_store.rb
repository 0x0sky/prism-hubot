# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  # Remembers, for a bounded TTL, which Hub-issued `idempotency_key`s this
  # client already relayed to Telegram, and the `provider_message_id` Telegram
  # returned for each. Hub's delivery worker retries a chunk whenever the HTTP
  # round trip to `/api/v1/delivery` fails or times out — including after this
  # client actually reached Telegram but the response never made it back — so
  # without this store a retried delivery would post the same chunk twice.
  #
  # Shaped after `FileInteractionStateStore`: same directory/TTL/atomic-write
  # discipline, because this is the same kind of thing — short-lived,
  # client-owned, disposable delivery bookkeeping, not business data. Losing
  # this store (a fresh directory, an expired entry) only risks a duplicate
  # Telegram message on an unlucky retry; it is never consulted to decide
  # whether a chunk is allowed to be delivered.
  class DeliveryIdempotencyStore
    FORMAT_VERSION = 1
    MAX_RECORD_BYTES = 1_024

    def initialize(directory:, ttl_seconds:, clock: -> { Time.now.to_i })
      @directory = File.expand_path(String(directory)).freeze
      @ttl_seconds = Integer(ttl_seconds)
      @clock = clock
      if @directory.empty? || @ttl_seconds <= 0 || !@clock.respond_to?(:call)
        raise ArgumentError, "invalid delivery idempotency store configuration"
      end

      FileUtils.mkdir_p(@directory, mode: 0o700)
    end

    # Returns the previously recorded provider_message_id for this
    # idempotency_key, or nil if it was never recorded or has expired.
    def fetch(idempotency_key:)
      path = path_for(idempotency_key)
      source = File.binread(path, MAX_RECORD_BYTES + 1)
      return nil if source.bytesize > MAX_RECORD_BYTES

      payload = JSON.parse(source)
      return nil unless payload.is_a?(Hash) && payload["version"] == FORMAT_VERSION

      if payload["expires_at"].is_a?(Integer) && payload["expires_at"] <= now
        delete(idempotency_key: idempotency_key)
        return nil
      end

      value = payload["provider_message_id"]
      value.is_a?(Integer) && value.positive? ? value : nil
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end

    def store(idempotency_key:, provider_message_id:)
      payload = {
        "version" => FORMAT_VERSION,
        "expires_at" => now + @ttl_seconds,
        "provider_message_id" => Integer(provider_message_id)
      }
      atomic_write(path_for(idempotency_key), JSON.generate(payload))
      nil
    end

    private

    def now
      Integer(@clock.call)
    end

    def delete(idempotency_key:)
      File.delete(path_for(idempotency_key))
    rescue Errno::ENOENT
      nil
    end

    def path_for(idempotency_key)
      key = String(idempotency_key)
      raise ArgumentError, "idempotency_key must not be empty" if key.empty?

      fingerprint = Digest::SHA256.hexdigest(key)
      File.join(@directory, "#{fingerprint}.json")
    end

    def atomic_write(path, source)
      temporary = "#{path}.tmp-#{Process.pid}-#{SecureRandom.hex(8)}"
      File.open(
        temporary,
        File::WRONLY | File::CREAT | File::EXCL,
        0o600
      ) do |file|
        file.write(source)
        file.flush
        file.fsync
      end
      File.rename(temporary, path)
    ensure
      File.delete(temporary) if temporary && File.exist?(temporary)
    end
  end
end

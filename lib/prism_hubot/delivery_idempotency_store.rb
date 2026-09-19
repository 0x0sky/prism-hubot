# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  # Best-effort duplicate suppression for `POST /api/v1/delivery`, keyed by
  # Hub's per-chunk `idempotency_key`. This is not an exactly-once guarantee:
  # Telegram's Bot API has no client-supplied idempotency key of its own, so
  # once a chunk reaches Telegram there is no way to ask "did I already send
  # this?" — only this store's own record of having tried.
  #
  # Each key moves through at most three states, mirroring the shape of Hub's
  # own `delivery_outbox_entries` (pending/processing/delivered) rather than
  # inventing a new one:
  #
  # - absent — never attempted, or a completed record expired;
  # - reserved (`status: "pending"`) — a delivery attempt is in flight, held
  #   for `reservation_ttl_seconds`;
  # - completed (`status: "completed"`) — Telegram accepted it; the record is
  #   held for `ttl_seconds` so a retried request can replay the result
  #   instead of calling Telegram again.
  #
  # `reserve` is the only path that creates a record, and it does so with an
  # atomic create-if-absent write, so two concurrent requests for the same key
  # cannot both proceed to Telegram: the loser observes `:in_progress` and the
  # caller answers 409, which Hub's own retry/backoff already handles.
  #
  # The one gap this cannot close: if this process dies between Telegram
  # accepting the chunk and `complete!` recording that fact — a real
  # possibility, since every `Deploy` restarts the service — the reservation
  # is orphaned. A later retry for the same key waits out
  # `reservation_ttl_seconds` and then steals the reservation, which can
  # duplicate that one message. `reservation_ttl_seconds` only needs to
  # outlast a genuine in-flight attempt (bounded by the outbound HTTP
  # timeouts), so that window is seconds, not minutes — but it is not zero,
  # and no file-based store on this side can make it zero.
  class DeliveryIdempotencyStore
    FORMAT_VERSION = 2
    MAX_RECORD_BYTES = 1_024
    STATUS_PENDING = "pending"
    STATUS_COMPLETED = "completed"

    Reservation = Data.define(:status, :provider_message_id) do
      def reserved? = status == :reserved

      def in_progress? = status == :in_progress

      def completed? = status == :completed
    end

    def initialize(directory:, ttl_seconds:, reservation_ttl_seconds:, clock: -> { Time.now.to_i })
      @directory = File.expand_path(String(directory)).freeze
      @ttl_seconds = Integer(ttl_seconds)
      @reservation_ttl_seconds = Integer(reservation_ttl_seconds)
      @clock = clock
      if @directory.empty? || @ttl_seconds <= 0 || @reservation_ttl_seconds <= 0 || !@clock.respond_to?(:call)
        raise ArgumentError, "invalid delivery idempotency store configuration"
      end

      FileUtils.mkdir_p(@directory, mode: 0o700)
    end

    # Atomically claims idempotency_key for a delivery attempt.
    #
    # Returns a Reservation:
    # - reserved?     — no attempt is on record (or a prior one went stale);
    #                    the caller must call `complete!` or `release`;
    # - in_progress?  — another attempt is already in flight; the caller
    #                    should answer without touching Telegram;
    # - completed?    — a prior attempt already succeeded; `provider_message_id`
    #                    is the result to replay, and Telegram is not called
    #                    again.
    def reserve(idempotency_key:)
      path = path_for(idempotency_key)
      claimed = create_pending(path)
      return Reservation.new(status: :reserved, provider_message_id: nil) if claimed

      settle_existing(path)
    end

    # Records a successful delivery, replacing the pending reservation.
    def complete!(idempotency_key:, provider_message_id:)
      payload = {
        "version" => FORMAT_VERSION,
        "status" => STATUS_COMPLETED,
        "expires_at" => now + @ttl_seconds,
        "provider_message_id" => Integer(provider_message_id)
      }
      atomic_write(path_for(idempotency_key), JSON.generate(payload))
      nil
    end

    # Releases a reservation that will not be completed (the delivery attempt
    # failed in a way this process observed), so an immediate retry is not
    # made to wait out reservation_ttl_seconds. Only removes a still-pending
    # record: never touches one another request already completed.
    def release(idempotency_key:)
      path = path_for(idempotency_key)
      record = read(path)
      File.delete(path) if record && record["status"] == STATUS_PENDING
      nil
    rescue Errno::ENOENT
      nil
    end

    private

    def now
      Integer(@clock.call)
    end

    def create_pending(path)
      payload = {"version" => FORMAT_VERSION, "status" => STATUS_PENDING, "reserved_at" => now}
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.generate(payload))
        file.flush
        file.fsync
      end
      true
    rescue Errno::EEXIST
      false
    end

    # Called only after `create_pending` lost the race to an existing file:
    # decides whether that file is a live reservation, a replayable result, or
    # stale enough (crashed holder, or unreadable) to steal.
    def settle_existing(path)
      record = read(path)
      return steal(path) if record.nil?

      case record["status"]
      when STATUS_COMPLETED
        value = record["provider_message_id"]
        if value.is_a?(Integer) && value.positive? && !expired?(record)
          return Reservation.new(status: :completed, provider_message_id: value)
        end

        steal(path)
      when STATUS_PENDING
        reserved_at = record["reserved_at"]
        if reserved_at.is_a?(Integer) && (now - reserved_at) < @reservation_ttl_seconds
          Reservation.new(status: :in_progress, provider_message_id: nil)
        else
          steal(path)
        end
      else
        steal(path)
      end
    end

    def steal(path)
      payload = {"version" => FORMAT_VERSION, "status" => STATUS_PENDING, "reserved_at" => now}
      atomic_write(path, JSON.generate(payload))
      Reservation.new(status: :reserved, provider_message_id: nil)
    end

    def expired?(record)
      record["expires_at"].is_a?(Integer) && record["expires_at"] <= now
    end

    def read(path)
      source = File.binread(path, MAX_RECORD_BYTES + 1)
      return nil if source.bytesize > MAX_RECORD_BYTES

      payload = JSON.parse(source)
      payload.is_a?(Hash) && payload["version"] == FORMAT_VERSION ? payload : nil
    rescue Errno::ENOENT, JSON::ParserError
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

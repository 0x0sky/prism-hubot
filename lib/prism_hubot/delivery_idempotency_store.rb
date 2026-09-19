# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  # Best-effort duplicate suppression for `POST /api/v1/delivery`, keyed by
  # Hub's per-chunk `idempotency_key`. This is not an exactly-once guarantee:
  # Telegram's Bot API has no client-supplied idempotency key of its own, so
  # once a chunk reaches Telegram there is no way to ask "did I already send
  # this?" — only this store's own record of having tried.
  #
  # Each key moves through at most three states:
  #
  # - absent — never attempted, or a completed record expired;
  # - reserved (`status: "pending"`) — a delivery attempt is in flight, held
  #   for `reservation_ttl_seconds`;
  # - completed (`status: "completed"`) — Telegram accepted it; the record is
  #   held for `ttl_seconds` so a retried request can replay the result
  #   instead of calling Telegram again.
  #
  # `with_key_lock` serializes the complete reservation/external-delivery/
  # completion sequence for one key across threads and processes sharing this
  # directory. This closes both the original fetch-then-act race and the stale
  # reservation steal race without creating a second lock-file lifecycle.
  #
  # The one gap this cannot close: if this process dies between Telegram
  # accepting the chunk and `complete!` recording that fact, a later retry
  # may eventually reclaim the pending reservation and duplicate that one
  # message. Telegram has no idempotent-send API, so a file store on this side
  # cannot make that crash window zero.
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

    # Holds an OS-level exclusive lock for the key across the entire
    # reservation -> Telegram -> completion sequence. The lock is released
    # automatically by the kernel if the process dies.
    def with_key_lock(idempotency_key)
      path = path_for(idempotency_key)
      File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        yield
      ensure
        file.flock(File::LOCK_UN) if file
      end
    end

    # Must be called inside with_key_lock.
    def reserve(idempotency_key:)
      path = path_for(idempotency_key)
      record = read(path)
      return Reservation.new(status: :reserved, provider_message_id: nil) if record.nil?

      case record["status"]
      when STATUS_COMPLETED
        value = record["provider_message_id"]
        return Reservation.new(status: :completed, provider_message_id: value) if value.is_a?(Integer) && value.positive? && !expired?(record)

        write_pending(path)
        Reservation.new(status: :reserved, provider_message_id: nil)
      when STATUS_PENDING
        reserved_at = record["reserved_at"]
        return Reservation.new(status: :in_progress, provider_message_id: nil) if reserved_at.is_a?(Integer) && (now - reserved_at) < @reservation_ttl_seconds

        write_pending(path)
        Reservation.new(status: :reserved, provider_message_id: nil)
      else
        write_pending(path)
        Reservation.new(status: :reserved, provider_message_id: nil)
      end
    end

    # Must be called inside with_key_lock.
    def complete!(idempotency_key:, provider_message_id:)
      path = path_for(idempotency_key)
      payload = {
        "version" => FORMAT_VERSION,
        "status" => STATUS_COMPLETED,
        "expires_at" => now + @ttl_seconds,
        "provider_message_id" => Integer(provider_message_id)
      }
      write_record(path, JSON.generate(payload))
      nil
    end

    # Must be called inside with_key_lock.
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

    def write_pending(path)
      payload = {"version" => FORMAT_VERSION, "status" => STATUS_PENDING, "reserved_at" => now}
      write_record(path, JSON.generate(payload))
    end

    def write_record(path, source)
      File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
        file.rewind
        file.write(source)
        file.truncate(file.pos)
        file.flush
        file.fsync
      end
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
  end
end

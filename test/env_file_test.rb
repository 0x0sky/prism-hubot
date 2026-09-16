# © 2026 aiaiaiai · aiaiaiai.org

require_relative "test_helper"

class EnvFileTest < Minitest::Test
  def test_reads_assignments_comments_and_blank_lines
    variables = parse(<<~ENV)
      # a comment
      ; also a comment

      PRISM_BOT_INSTANCE_ID=prism-hubot
        PRISM_BOT_DEFAULT_LOCALE=uk-UA
      PRISM_BOT_ALLOW_INSECURE_HTTP=false
    ENV

    assert_equal(
      {
        "PRISM_BOT_INSTANCE_ID" => "prism-hubot",
        "PRISM_BOT_DEFAULT_LOCALE" => "uk-UA",
        "PRISM_BOT_ALLOW_INSECURE_HTTP" => "false"
      },
      variables
    )
  end

  # The deployment that motivated this reader died on `line 2: syntax error
  # near unexpected token 'newline'`: `bash` read an angle-bracket placeholder
  # as a redirection. systemd reads the same line as a value, and so do we.
  def test_keeps_shell_syntax_verbatim
    variables = parse(<<~ENV)
      PRISM_BOT_TELEGRAM_TOKEN=<from-botfather>
      PRISM_BOT_TELEGRAM_WEBHOOK_SECRET=a|b&c;d
      PRISM_HUB_API_TOKEN=$(cat /etc/shadow)
      PRISM_HUB_BASE_URL=https://hub.example.test/?a=1&b=2
      PRISM_BOT_DEFAULT_VOICE_PROFILE=0x0sky.uk_SP#dev
    ENV

    assert_equal "<from-botfather>", variables.fetch("PRISM_BOT_TELEGRAM_TOKEN")
    assert_equal "a|b&c;d", variables.fetch("PRISM_BOT_TELEGRAM_WEBHOOK_SECRET")
    assert_equal "$(cat /etc/shadow)", variables.fetch("PRISM_HUB_API_TOKEN")
    assert_equal "https://hub.example.test/?a=1&b=2", variables.fetch("PRISM_HUB_BASE_URL")
    assert_equal "0x0sky.uk_SP#dev", variables.fetch("PRISM_BOT_DEFAULT_VOICE_PROFILE")
  end

  def test_bash_rejects_a_file_systemd_and_this_reader_accept
    skip "bash is not available" unless system("command -v bash >/dev/null 2>&1")

    Dir.mktmpdir do |directory|
      path = File.join(directory, ".env")
      File.write(path, "# © 2026 aiaiaiai · aiaiaiai.org\nPRISM_BOT_TELEGRAM_TOKEN=<from-botfather>\n")

      refute system("bash", "-c", ". #{path}", out: File::NULL, err: File::NULL)
      assert_equal(
        {"PRISM_BOT_TELEGRAM_TOKEN" => "<from-botfather>"},
        PrismHubot::EnvFile.read(path)
      )
    end
  end

  def test_quoted_values
    variables = parse(<<~ENV)
      SINGLE='  spaced # value  '
      DOUBLE="line one
      line two"
      JOINED="a"'b'c
      EMPTY=
    ENV

    assert_equal "  spaced # value  ", variables.fetch("SINGLE")
    assert_equal "line one\nline two", variables.fetch("DOUBLE")
    assert_equal "abc", variables.fetch("JOINED")
    assert_equal "", variables.fetch("EMPTY")
  end

  def test_escapes_and_line_continuation
    variables = parse(<<~'ENV')
      ESCAPED=a\ b\#c
      CONTINUED=first \
      second
      QUOTED_ESCAPE="he said \"no\""
    ENV

    assert_equal "a b#c", variables.fetch("ESCAPED")
    assert_equal "first second", variables.fetch("CONTINUED")
    assert_equal 'he said "no"', variables.fetch("QUOTED_ESCAPE")
  end

  def test_drops_trailing_whitespace_and_carriage_returns
    variables = parse("PADDED=  value with spaces  \r\nLAST=tail")

    assert_equal "value with spaces", variables.fetch("PADDED")
    assert_equal "tail", variables.fetch("LAST")
  end

  def test_skips_what_systemd_skips_and_says_where
    warnings = []
    variables = parse(<<~ENV, warnings)
      export PRISM_HUB_API_TOKEN=secret
      PRISM_BOT_DEFAULT_LOCALE = uk-UA
      PRISM_BOT_DISPATCH_POLICY
      1_INVALID=x
      PRISM_BOT_INSTANCE_ID=prism-hubot
    ENV

    assert_equal({"PRISM_BOT_INSTANCE_ID" => "prism-hubot"}, variables)
    assert_equal 4, warnings.length
    assert_match(/line 1: .*`PRISM_HUB_API_TOKEN`.*export/, warnings[0])
    assert_match(/line 2: .*`PRISM_BOT_DEFAULT_LOCALE`.*whitespace around `=`/, warnings[1])
    assert_match(/line 3: .*without `=`/, warnings[2])
    assert_match(/line 4: .*`1_INVALID`/, warnings[3])
  end

  def test_reports_an_unterminated_quoted_value
    warnings = []
    variables = parse("PRISM_HUB_API_TOKEN=\"never closed\n", warnings)

    assert_empty variables
    assert_match(/line 1: .*`PRISM_HUB_API_TOKEN`.*never closed/, warnings.first)
  end

  def test_warnings_name_the_file
    Dir.mktmpdir do |directory|
      path = File.join(directory, ".env")
      File.write(path, "export PRISM_HUB_API_TOKEN=secret\n")
      warnings = []

      PrismHubot::EnvFile.read(path, on_warning: ->(message) { warnings << message })

      assert_match(/\A#{Regexp.escape(path)}: line 1: /, warnings.first)
    end
  end

  def test_read_raises_for_a_missing_file
    Dir.mktmpdir do |directory|
      assert_raises(Errno::ENOENT) { PrismHubot::EnvFile.read(File.join(directory, "absent")) }
    end
  end

  def test_apply_leaves_variables_the_process_already_has
    Dir.mktmpdir do |directory|
      path = File.join(directory, ".env")
      File.write(path, "PRISM_BOT_INSTANCE_ID=from-file\nPRISM_BOT_DEFAULT_LOCALE=uk-UA\n")
      environment = {"PRISM_BOT_INSTANCE_ID" => "from-the-command-line"}

      applied = PrismHubot::EnvFile.apply!(path, environment: environment)

      assert_equal ["PRISM_BOT_DEFAULT_LOCALE"], applied
      assert_equal "from-the-command-line", environment.fetch("PRISM_BOT_INSTANCE_ID")
      assert_equal "uk-UA", environment.fetch("PRISM_BOT_DEFAULT_LOCALE")
    end
  end

  # `.env.example` is what operators copy onto the VPS, so it has to be a file
  # systemd can read.
  def test_the_example_file_parses_without_warnings
    warnings = []
    path = File.expand_path("../.env.example", __dir__)
    variables = PrismHubot::EnvFile.read(path, on_warning: ->(message) { warnings << message })

    assert_empty warnings
    assert_equal "prism-hubot", variables.fetch("PRISM_BOT_INSTANCE_ID")
    assert_equal "var/interaction-state", variables.fetch("PRISM_HUBOT_INTERACTION_STATE_DIR")
    assert_equal "900", variables.fetch("PRISM_HUBOT_INTERACTION_STATE_TTL_SECONDS")
  end

  private

  def parse(source, warnings = nil)
    PrismHubot::EnvFile.parse(source, on_warning: warnings && ->(message) { warnings << message })
  end
end

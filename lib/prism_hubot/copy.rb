# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Copy
    HELP = <<~TEXT.freeze
      Prism Hubot:
      #{CommandMenu.help_lines}

      /publish текст — публікація у типові канали.
      /publish [channel-a,channel-b] текст — публікація у вибрані канали.
      Можна також написати «зробити допис» без команди.
    TEXT

    POST_PROMPT = "Надішли текст допису наступним повідомленням. /cancel — скасувати.".freeze
    EMPTY_POST = "Текст допису порожній. Надішли текст або /cancel.".freeze
    CANCELLED = "Поточну дію скасовано.".freeze
  end
end

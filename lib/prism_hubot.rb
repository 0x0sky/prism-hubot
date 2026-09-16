# © 2026 aiaiaiai · aiaiaiai.org

require "digest"
require "fileutils"
require "json"
require "securerandom"

require "prism_bot"

require_relative "prism_hubot/configuration"
require_relative "prism_hubot/command_menu"
require_relative "prism_hubot/copy"
require_relative "prism_hubot/file_interaction_state_store"
require_relative "prism_hubot/presenter"
require_relative "prism_hubot/handlers/begin_post"
require_relative "prism_hubot/handlers/await_post_content"
require_relative "prism_hubot/handlers/cancel"
require_relative "prism_hubot/fallback"
require_relative "prism_hubot/client"

module PrismHubot
  class StateStoreError < PrismBot::Error; end
end

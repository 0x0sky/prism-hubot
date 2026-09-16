# © 2026 aiaiaiai · aiaiaiai.org

require "json"
require "net/http"
require "uri"

require_relative "../prism_hubot/command_menu"

namespace :telegram do
  desc "Publish the command menu to Telegram (setMyCommands)"
  task :commands do
    commands = PrismHubot::CommandMenu.telegram_commands
    TelegramMenuTask.call("setMyCommands", {"commands" => commands})
    puts "Published #{commands.length} commands to the Telegram menu."
    puts commands.map { "  /#{_1["command"]} — #{_1["description"]}" }
  end

  desc "Show the command menu Telegram currently serves (getMyCommands)"
  task :commands_status do
    published = TelegramMenuTask.call("getMyCommands", {}).fetch("result", [])
    if published.empty?
      puts "Telegram serves no commands for this bot. Run `rake telegram:commands`."
    else
      puts published.map { "  /#{_1["command"]} — #{_1["description"]}" }
    end
  end
end

# Minimal Bot API caller for the menu methods. Publishing the menu is a
# deployment-time operation, not part of the request path, so it deliberately
# does not go through the runtime Telegram adapter.
module TelegramMenuTask
  API_HOST = "https://api.telegram.org".freeze

  module_function

  def call(method, payload)
    token = ENV["PRISM_BOT_TELEGRAM_TOKEN"].to_s
    if token.empty?
      abort "PRISM_BOT_TELEGRAM_TOKEN is not set. Source the deployment .env before running this task."
    end

    response = Net::HTTP.post(
      URI("#{API_HOST}/bot#{token}/#{method}"),
      JSON.generate(payload),
      "accept" => "application/json",
      "content-type" => "application/json"
    )
    body = parse(response.body)
    unless response.code == "200" && body["ok"] == true
      abort "Telegram rejected #{method}: HTTP #{response.code} #{body["description"] || "no description"}"
    end

    body
  end

  def parse(body)
    value = JSON.parse(String(body))
    value.is_a?(Hash) ? value : {}
  rescue JSON::ParserError
    {}
  end
end

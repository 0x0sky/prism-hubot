# © 2026 aiaiaiai · aiaiaiai.org

require "json"
require "net/http"
require "uri"

require_relative "../prism_hubot/command_menu"

namespace :telegram do
  desc "Publish the command menu to Telegram (setMyCommands)"
  task commands: "env:load" do
    commands = PrismHubot::CommandMenu.telegram_commands
    TelegramBotApiTask.call("setMyCommands", {"commands" => commands})
    puts "Published #{commands.length} commands to the Telegram menu."
    puts commands.map { "  /#{_1["command"]} — #{_1["description"]}" }
  end

  desc "Show the command menu Telegram currently serves (getMyCommands)"
  task commands_status: "env:load" do
    published = TelegramBotApiTask.call("getMyCommands", {}).fetch("result", [])
    if published.empty?
      puts "Telegram serves no commands for this bot. Run `rake telegram:commands`."
    else
      puts published.map { "  /#{_1["command"]} — #{_1["description"]}" }
    end
  end

  desc "Point Telegram at this deployment's webhook (setWebhook)"
  task webhook: "env:load" do
    url = ENV["PRISM_HUBOT_WEBHOOK_URL"].to_s
    secret = ENV["PRISM_BOT_TELEGRAM_WEBHOOK_SECRET"].to_s
    if url.empty?
      abort "PRISM_HUBOT_WEBHOOK_URL is not set. It is the public HTTPS URL of /telegram/webhook."
    end
    unless url.start_with?("https://")
      abort "PRISM_HUBOT_WEBHOOK_URL must be an https:// URL; Telegram refuses anything else."
    end
    if secret.empty?
      abort "PRISM_BOT_TELEGRAM_WEBHOOK_SECRET is not set. The process rejects updates without it."
    end

    TelegramBotApiTask.call(
      "setWebhook",
      {"url" => url, "secret_token" => secret, "drop_pending_updates" => false}
    )
    puts "Telegram now delivers updates to #{url}."
  end

  desc "Show what Telegram knows about the webhook (getWebhookInfo)"
  task webhook_status: "env:load" do
    info = TelegramBotApiTask.call("getWebhookInfo", {}).fetch("result", {})
    url = String(info["url"])
    if url.empty?
      puts "No webhook is registered. This bot receives no updates. Run `rake telegram:webhook`."
    else
      puts "url:                  #{url}"
      puts "pending updates:      #{info["pending_update_count"]}"
      puts "last error:           #{info["last_error_message"] || "none"}"
      puts "last error at:        #{info["last_error_date"] ? Time.at(info["last_error_date"]).utc : "never"}"
    end
  end
end

# Minimal Bot API caller for the menu and webhook methods. Both are
# deployment-time operations, not part of the request path, so this
# deliberately does not go through the runtime Telegram adapter.
module TelegramBotApiTask
  API_HOST = "https://api.telegram.org".freeze

  module_function

  def call(method, payload)
    token = ENV["PRISM_BOT_TELEGRAM_TOKEN"].to_s
    if token.empty?
      abort "PRISM_BOT_TELEGRAM_TOKEN is not set. `rake env:check` reports what the deployment .env defines."
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

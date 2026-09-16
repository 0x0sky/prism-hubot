# © 2026 aiaiaiai · aiaiaiai.org

require_relative "../prism_hubot/env_file"

namespace :env do
  desc "Load the deployment environment file into this process"
  task :load do
    path = DeploymentEnvFile.path
    if path
      applied = DeploymentEnvFile.guard { PrismHubot::EnvFile.apply!(path) }
      puts "Loaded #{DeploymentEnvFile.plural(applied.length, "variable")} from #{path}."
    end
  end

  desc "Report what systemd reads from the deployment environment file (names only)"
  task :check do
    path = DeploymentEnvFile.path
    abort DeploymentEnvFile::NOT_FOUND unless path

    problems = []
    variables = DeploymentEnvFile.guard do
      PrismHubot::EnvFile.read(path, on_warning: ->(message) { problems << message })
    end

    puts "#{path}: #{DeploymentEnvFile.plural(variables.length, "variable")}"
    puts variables.keys.sort.map { "  #{_1}" }
    unless problems.empty?
      $stdout.flush
      problems.each { warn _1 }
      abort "#{path}: systemd ignores #{DeploymentEnvFile.plural(problems.length, "line")} above; the service starts without what they define."
    end
  end
end

# Locates the file deployment tasks read: `PRISM_HUBOT_ENV_FILE` when set,
# otherwise `.env` in the working directory, which in a release is the symlink
# to `shared/.env` that systemd also reads.
module DeploymentEnvFile
  NOT_FOUND = "No environment file. Set PRISM_HUBOT_ENV_FILE, or run from a release directory.".freeze

  module_function

  def path
    configured = ENV["PRISM_HUBOT_ENV_FILE"].to_s
    unless configured.empty?
      abort "PRISM_HUBOT_ENV_FILE points at #{configured}, which does not exist." unless File.exist?(configured)
      return configured
    end

    default = File.expand_path(".env")
    File.exist?(default) ? default : nil
  end

  def plural(count, noun)
    "#{count} #{count == 1 ? noun : "#{noun}s"}"
  end

  def guard
    yield
  rescue SystemCallError, ArgumentError => error
    abort "Cannot read the environment file: #{error.message}"
  end
end

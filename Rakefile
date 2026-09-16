# © 2026 aiaiaiai · aiaiaiai.org

require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
end

Dir.glob(File.expand_path("lib/tasks/*.rake", __dir__)).sort.each { load _1 }

task default: :test

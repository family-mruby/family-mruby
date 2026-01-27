require 'yaml'
require 'fileutils'

REPOS_FILE = '.repos'

# Load .repos file
def load_repos
  unless File.exist?(REPOS_FILE)
    puts "Error: #{REPOS_FILE} not found"
    exit 1
  end

  config = YAML.load_file(REPOS_FILE)
  config['repositories']
end

# Clone or update repository
def fetch_repository(name, info, version = nil)
  target_version = version || info['version']
  url = info['url']

  puts "Fetching #{name} (#{target_version})..."

  begin
    if Dir.exist?(name)
      # Update if already exists
      Dir.chdir(name) do
        sh "git fetch origin"
        sh "git checkout #{target_version}"
        sh "git pull origin #{target_version}" rescue nil
        sh "git submodule update --init --recursive" rescue nil
      end
    else
      # Clone new repository with submodules
      sh "git clone --recursive #{url} #{name}"
      Dir.chdir(name) do
        sh "git checkout #{target_version}"
        sh "git submodule update --init --recursive" rescue nil
      end
    end

    puts "✓ #{name} fetched successfully"
    true
  rescue => e
    puts "✗ #{name} failed: #{e.message}"
    false
  end
end

# Default task
desc "Show available tasks"
task :default do
  sh "rake -T"
end

# Fetch all repositories with default branch from .repos
desc "Fetch all repositories (using version from .repos)"
task :fetch, [:branch] do |t, args|
  repos = load_repos
  results = []

  if args[:branch]
    # If branch is specified as argument
    puts "Fetching all repositories with branch/tag: #{args[:branch]}"
    repos.each do |name, info|
      results << fetch_repository(name, info, args[:branch])
    end
  else
    # Use default version from .repos
    repos.each do |name, info|
      results << fetch_repository(name, info)
    end
  end

  success_count = results.count(true)
  fail_count = results.count(false)

  puts "\n" + "=" * 60
  puts "Summary: #{success_count} succeeded, #{fail_count} failed"
  puts "=" * 60
end

# Create dynamic tasks for fetch:branch_name pattern
rule /^fetch:/ do |t|
  branch = t.name.sub('fetch:', '')

  if branch.empty?
    puts "Error: Please specify branch or tag (e.g., rake fetch:develop)"
    exit 1
  end

  repos = load_repos

  puts "Fetching all repositories with branch/tag: #{branch}"
  repos.each do |name, info|
    fetch_repository(name, info, branch)
  end

  puts "\n✓ All repositories fetched successfully!"
end

# Fetch specific repository
desc "Fetch a specific repository (usage: rake fetch_repo[repo_name,branch])"
task :fetch_repo, [:name, :branch] do |t, args|
  repos = load_repos

  unless args[:name]
    puts "Available repositories:"
    repos.keys.each { |name| puts "  - #{name}" }
    exit 0
  end

  unless repos[args[:name]]
    puts "Error: Repository '#{args[:name]}' not found in #{REPOS_FILE}"
    exit 1
  end

  fetch_repository(args[:name], repos[args[:name]], args[:branch])
end

# Show status
desc "Show status of all repositories"
task :status do
  repos = load_repos

  puts "Repository Status:"
  puts "=" * 60

  repos.each do |name, info|
    if Dir.exist?(name)
      Dir.chdir(name) do
        puts "\n#{name}:"
        sh "git status -s"
        current_branch = `git rev-parse --abbrev-ref HEAD`.strip
        puts "  Current branch: #{current_branch}"
      end
    else
      puts "\n#{name}: Not cloned yet"
    end
  end
end

# Clean up
desc "Remove all cloned repositories"
task :clean do
  repos = load_repos

  print "Are you sure you want to remove all repositories? (y/N): "
  answer = STDIN.gets.chomp

  if answer.downcase == 'y'
    repos.keys.each do |name|
      if Dir.exist?(name)
        puts "Removing #{name}..."
        FileUtils.rm_rf(name)
      end
    end
    puts "✓ All repositories removed"
  else
    puts "Cancelled"
  end
end

# Build tasks - execute rake task in each repository
namespace :build do
  desc "Execute 'rake build:linux' in each repository"
  task :linux do
    repos = load_repos
    results = []

    repos.keys.each do |name|
      if Dir.exist?(name)
        puts "\n" + "=" * 60
        puts "Building #{name} for Linux..."
        puts "=" * 60

        Dir.chdir(name) do
          if File.exist?('Rakefile')
            begin
              sh "rake build:linux"
              puts "✓ #{name} built successfully"
              results << true
            rescue => e
              puts "✗ #{name} build failed: #{e.message}"
              results << false
            end
          else
            puts "⊘ #{name} has no Rakefile, skipping..."
            results << nil
          end
        end
      else
        puts "✗ #{name} directory not found, skipping..."
        results << false
      end
    end

    success_count = results.count(true)
    fail_count = results.count(false)
    skip_count = results.count(nil)

    puts "\n" + "=" * 60
    puts "Build Summary: #{success_count} succeeded, #{fail_count} failed, #{skip_count} skipped"
    puts "=" * 60
  end
end

# Generic task runner - execute any rake task in each repository
desc "Execute a rake task in each repository (usage: rake run_task[task_name])"
task :run_task, [:task_name] do |t, args|
  unless args[:task_name]
    puts "Error: Please specify a task name (e.g., rake run_task[build:linux])"
    exit 1
  end

  repos = load_repos
  task_name = args[:task_name]
  results = []

  repos.keys.each do |name|
    if Dir.exist?(name)
      puts "\n" + "=" * 60
      puts "Running '#{task_name}' in #{name}..."
      puts "=" * 60

      Dir.chdir(name) do
        if File.exist?('Rakefile')
          begin
            sh "rake #{task_name}"
            puts "✓ #{name} completed successfully"
            results << true
          rescue => e
            puts "✗ #{name} failed: #{e.message}"
            results << false
          end
        else
          puts "⊘ #{name} has no Rakefile, skipping..."
          results << nil
        end
      end
    else
      puts "✗ #{name} directory not found, skipping..."
      results << false
    end
  end

  success_count = results.count(true)
  fail_count = results.count(false)
  skip_count = results.count(nil)

  puts "\n" + "=" * 60
  puts "Summary: #{success_count} succeeded, #{fail_count} failed, #{skip_count} skipped"
  puts "=" * 60
end

# frozen_string_literal: true
require 'things/issues_diff/version'

require 'optparse'
require 'octokit'
require 'yaml'

class Things::IssuesDiff
  def parse_options(argv)
    opts = OptionParser.new

    opts.on('-h', '--help', 'Show help') do
      usage
    end

    @args = {}
    opts.on('-c FILE', '--config', 'Config file') do |v|
      @args[:config_file] = v
    end
    opts.on('--ignore-filter', 'Do not filter issues/tasks') do |v|
      @args[:ignore_filter] = v
    end
    opts.parse!(argv)

    commands = argv[0].nil? ? [] : argv.shift.split(/\s*,\s*/)
    @commands = %w[help sampleconf fetch diff].& commands
  end

  def load_config
    default_config_file = File.join(ENV['HOME'], '.things-diff/config.yml')
    @config_file = @args[:config_file] || default_config_file
    unless File.exist?(@config_file)
      puts "Error: Config file not found: #{@config_file}"

      unless File.exist?(default_config_file)
        puts
        puts 'Please create config.yml and edit.'
        puts '  $ mkdir ~/.things-diff/'
        puts '  $ things-diff sampleconf > ~/.things-diff/config.yml'
        puts '  $ vi ~/.things-diff/config.yml'
      end
      exit 1
    end
    @config_file = File.absolute_path(@config_file)
    @config = YAML.load_file(@config_file)

    if @config['data_file']
      @data_file = File.join(File.dirname(@config_file), @config['data_file'])
      @data_file = File.absolute_path(@data_file)
    else
      puts 'Error: Please set the data_file'
      exit 1
    end
  end

  # https://octokit.github.io/octokit.rb/
  def init_octokit
    @client = Octokit::Client.new(access_token: @config['token'])
    @client.auto_paginate = true
  end

  def execute(argv)
    parse_options(argv)
    if @commands.include?('help')
      usage
    end

    if @commands.include?('sampleconf')
      sample_config
      exit
    end

    load_config
    init_octokit

    if @commands.empty?
      usage
    end

    if @commands.include?('fetch')
      fetch
    end

    if @commands.include?('diff')
      diff
    end
  end

  def fetch
    result = {}
    @config['projects'].each do |project|
      puts "Loading: #{project['name']}"
      result[project['name']] = {}
      issues = @client.list_issues(project['name'], assignee: @config['user'])
      issues.each do |issue|
        labels = []
        if issue[:labels]
          labels = issue[:labels].map { |lbl| lbl[:name] }
        end

        milestone = issue[:milestone] ? issue[:milestone][:title] : ''
        entry = {
          'title' => issue[:title],
          'url' => issue[:html_url],
          'milestone' => milestone,
          'labels' => labels
        }
        result[project['name']][issue[:number].to_i] = entry
      end
    end
    yaml = YAML.dump(result)
    File.open(@data_file, 'w') do |out|
      out << yaml
    end
    puts "Saved: #{@data_file}"
  end

  def diff
    all_issues = YAML.load_file(@data_file)
    all_tasks = load_tasks
    @config['projects'].each do |project|
      issues = all_issues[project['name']] || {}
      tasks = all_tasks[project['name']] || {}

      unless @args[:ignore_filter]
        excludes = project.dig('milestones', 'exclude') || []
        includes = project.dig('milestones', 'include') || []

        unless includes.empty?
          issues = issues.select { |_, v| includes.include?(v['milestone']) }
        end
        unless excludes.empty?
          issues = issues.reject { |_, v| excludes.include?(v['milestone']) }
        end
      end

      new_issues = (issues.keys - tasks.keys).map { |number| issues[number] }
      old_tasks = (tasks.keys - issues.keys).map { |number| tasks[number] }

      if new_issues.empty? && old_tasks.empty?
        puts "--- #{project['name']}: Clear! ---"
        next
      end

      puts
      puts "--- #{project['name']}: Only exists in the GitHub issues (#{new_issues.length}) ---"
      puts
      new_issues.each do |issue|
        puts issue['title']
        puts issue['url'] + '  ' + issue['milestone']
        puts
      end
      puts
      puts "--- #{project['name']}: Only exists in the Things tasks (#{old_tasks.length}) ---"
      puts
      old_tasks.each do |task|
        puts task['title']
        puts task['url']
        puts
      end
    end
  end

  def load_tasks
    tasks = `things.sh all`.split(/\r?\n/)
    project_names = @config['projects'].map { |prj| prj['name'] }
    result = project_names.map { |name| [name, {}] }.to_h
    tasks.each do |task|
      project_names.each do |name|
        next unless task.include?(name)
        next unless task =~ /\sIssue #(\d+)\s/

        number = Regexp.last_match[1].to_i
        if result[name][number]
          puts "WARN: duplicated #{name} #{number}"
        end
        result[name][number] = {
          'url' => "https://github.com/#{name}/issues/#{number}",
          'title' => task
        }
      end
    end
    result
  end

  def usage
    puts 'Usage: things.rb --config FILE [help|sampleconf|fetch|diff]'
    exit 1
  end

  def sample_config
    puts <<END_OF_CONFIG
# ----------------------------------------------------------------
# things-diff config file
# https://github.com/koseki/things-issues-diff
#
# $ mkdir ~/.things-diff
# $ things-diff sampleconf > ~/.things-diff/config.yml
# ----------------------------------------------------------------

# Create a token with the repo scope.
# https://github.com/settings/tokens/new
token: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# The relative path is based on the config file.
data_file: data.yml

user: assignee-user-name
projects:
  - name: repos/path
    milestones:
      exclude:
        - Icebox
        - Backlog
    labels:
      include:
        - important

  - name: repos/path2
  - name: repos/path3

END_OF_CONFIG
  end
end

Things::IssuesDiff.new.execute(ARGV)

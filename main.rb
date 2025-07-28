#!/usr/bin/env ruby

require "faraday"
require "rugged"
require "linguist"
require "rainbow"
require "optparse"
require "io/console"

options = { :repo => ".", :mode => "sass", :range => nil }
OptionParser.new do |opt|
  opt.on("-r", "--repo REPO_PATH", "Path to the git repository")
  opt.on("--mode MODE", "Modes: constructive, critical, sass")
  opt.on("--range RANGE", "Commit range to judge in format <commit1>..<commit2>")
end.parse!(into: options)

begin
  repo = Rugged::Repository.new(options[:repo])
rescue Rugged::RepositoryError
  puts "Not a repository"
  exit 1
rescue StandardError
  puts "Error while reading repository"
  exit 1
end

if repo.branches.entries.empty?
  puts "Your git repository is empty. Please have at least 1 commit"
  exit 1
end

conn = Faraday.new(
  url: "https://ai.hackclub.com",
  headers: { "Content-Type" => "application/json" },
) do |builder|
  builder.response :json
end

prompt = {
  "sass" => "Write a funny and sassy comment on this commit.",
  "constructive" => "Write a short constructive comment on this commit.",
  "critical" => "Write a short critical comment on this commit.",
}[options[:mode]]

if prompt == nil
  puts "Please use one of the allowed modes!"
  exit 1
end

walker = Rugged::Walker.new(repo)
walker.sorting(Rugged::SORT_TOPO)

begin
  if options[:range] == nil
    start_commit = repo.head.target
  else
    range = options[:range].split("..")
    start_commit = repo.lookup(range[1])
  end
rescue Rugged::OdbError
  puts "Start commit does not exist"
  exit 1
rescue StandardError
  puts "Error while searching for start commit"
  exit 1
end

walker.push(start_commit)
first = true
walker.each { |commit|
  files_to_diff = []

  parent_tree = commit.parents[0]&.tree || Rugged::Tree.empty(repo)
  parent_tree.diff(commit.tree).each_delta { |delta|
    new_file = delta.new_file
    generated = false
    if delta.status != :deleted
      blob = Linguist::LazyBlob.new(repo, new_file[:oid], new_file[:path])
      generated = blob.generated?
    end
    if !generated
      files_to_diff << new_file[:path]
    end
  }
  diff = parent_tree.diff(commit.tree, { :paths => files_to_diff, :disable_pathspec_match => true }).patch
  response = conn.post("/chat/completions", {
    "messages" => [
      { "role" => "system", "content" =>"You judge commits with the specified style. Do not output markdown, output only plain text!" },
      { "role" => "user", "content" =>  prompt + " Do not output anything else!\n#{commit.message}\n#{diff}" },
    ],
  }.to_json).body["choices"][0]["message"]["content"]

  if response.include? "<think>"
    response = response.split("</think>")[1]
  end
  response.strip!
  response = response.delete_prefix('"').delete_suffix('"')

  # Wait for space
  if !first && $stdin.getch != " "
    break
  end
  # Clear buffer
  while $stdin.ready?
    $stdin.getch
  end

  puts "\bcommit #{commit.oid[0, 7]} #{Rainbow("by #{commit.author[:name]}").blue}"
  puts Rainbow(commit.message.lines[0]).cyan.bright
  puts "#{Rainbow(response).red.bright}\n\n"

  # Stop at end of range
  if options[:range] != nil && commit.oid == range[0]
    break
  end
  first = false
}

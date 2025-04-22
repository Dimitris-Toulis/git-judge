#!/usr/bin/env ruby

require "faraday"
require "rugged"
require "linguist"
require "rainbow"
require "optparse"
require "io/console"

options = { :repo => ".", :mode => "sass" }
OptionParser.new do |opt|
  opt.on("-r", "--repo REPO_PATH", "Path to the git repository")
  opt.on("--mode MODE", "Modes: constructive, critical, sass")
  opt.on("--range RANGE")
end.parse!(into: options)

repo = Rugged::Repository.new(options[:repo])
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
walker.push(repo.head.target)
first = true
walker.each { |commit|
  cleaned_diff = ""
  parent_tree = commit.parents[0]&.tree || Rugged::Tree.empty(repo)
  diff = parent_tree.diff(commit.tree)
  diff.each_delta { |delta|
    new_file = delta.new_file
    generated = false
    if delta.status != :deleted
      blob = Linguist::LazyBlob.new(repo, new_file[:oid], new_file[:path])
      generated = blob.generated?
    end
    if !generated
      file_diff = parent_tree.diff(commit.tree, { :paths => [new_file[:path]], :disable_pathspec_match => true }).patch
      cleaned_diff << file_diff
    end
  }
  response = conn.post("/chat/completions", {
    "messages" => [
      { "role" => "system", "content" => prompt + " Do not output anything else!" },
      { "role" => "user", "content" => "#{commit.message}\n#{cleaned_diff}" },
    ],
  }.to_json)
  if !first && $stdin.getch != " "
    break
  end
  puts "\bcommit #{commit.oid[0, 7]} #{Rainbow("by #{commit.author[:name]}").blue}"
  puts Rainbow(commit.message.lines[0]).cyan.bright
  puts "	#{Rainbow(response.body["choices"][0]["message"]["content"].delete_prefix('"').delete_suffix('"')).red.bright}\n\n"
  first = false
}
walker.reset

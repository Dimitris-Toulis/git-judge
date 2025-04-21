#!/usr/bin/env ruby

require "faraday"
require 'rugged'
require 'linguist'
require 'rainbow'

repo = Rugged::Repository.new('.')
conn = Faraday.new(
	url: 'https://ai.hackclub.com',
	headers: {'Content-Type' => 'application/json'}
) do |builder|
	builder.response :json
end

walker = Rugged::Walker.new(repo)
walker.sorting(Rugged::SORT_TOPO)
walker.push(repo.head.target)
i = 0
walker.each { |c|
	i += 1
	if i == 5
		walker.reset
	end
	cleaned_diff = ""
	diff = c.parents[0].diff(c)
	diff.each_delta { |delta|
		new_file = delta.new_file
		old_file = delta.old_file
		skip = false
		if delta.status != :deleted
			blob = Linguist::LazyBlob.new(repo, new_file[:oid], new_file[:path])
			skip = blob.generated? || blob.vendored?
		end
		if !skip
			old_blob = delta.status != :added ? repo.lookup(old_file[:oid]) : nil
			new_blob = delta.status != :deleted ? repo.lookup(new_file[:oid]) : nil
			file_diff = old_blob.diff(new_blob).to_s().gsub("a/file",old_file[:path]).gsub("b/file",new_file[:path])
			cleaned_diff << file_diff
		end
	}
	response = conn.post('/chat/completions',{
		"messages" => [
	 		{"role"=>"system","content"=>"Write a funny and sassy comment on this commit. Do not output anything else!"},
	 		{"role"=>"user","content"=>"#{c.message}\n#{cleaned_diff}"}
		]
	}.to_json)
	puts Rainbow("commit " + c.oid[0, 7]) + Rainbow(" by #{c.author[:name]}").blue.bright
	puts Rainbow(c.message.lines[0]).cyan.bright
	puts "	" + Rainbow(response.body["choices"][0]["message"]["content"][1..-2]).red.bright
	puts ""
}
walker.reset
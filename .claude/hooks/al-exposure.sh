#!/bin/bash

payload=$(cat) || exit 0
[[ "$payload" == *applied-learning-* ]] || exit 0

printf '%s' "$payload" | ruby -rjson -rtime -rfileutils -e '
  begin
    event = JSON.parse(STDIN.read)
    input = event.fetch("tool_input", {})
    subset = {}
    %w[file_path offset limit pattern path command].each do |key|
      next unless input.key?(key)
      subset[key] = key == "command" ? input[key].to_s[0, 500] : input[key]
    end
    root = ENV["CLAUDE_PROJECT_DIR"]
    root = Dir.pwd if root.nil? || root.empty?
    directory = File.join(root, ".claude", "state")
    FileUtils.mkdir_p(directory)
    row = {ts: Time.now.utc.iso8601, session_id: event["session_id"],
           tool_name: event["tool_name"], tool_input: subset}
    File.open(File.join(directory, "al-exposure.jsonl"), "a") do |file|
      file.flock(File::LOCK_EX)
      file.write(JSON.generate(row) + "\n")
    end
  rescue StandardError
    # Observability must never prevent the underlying tool from completing.
  end
' >/dev/null 2>&1
exit 0

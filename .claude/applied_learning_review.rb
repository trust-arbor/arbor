#!/usr/bin/env ruby

# Offline usage harvesting and approved, transactional Applied Learning edits.
require "date"
require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "set"

module AppliedLearningReview
  INVENTORY = ".claude/skills/applied-learning-inventory.json".freeze
  USAGE = ".claude/skills/applied-learning-usage.json".freeze
  CITATION = /\[AL:([a-z0-9][a-z0-9-]*)(!)?\]/
  CLASSES = %w[security-invariant correctness process tooling].freeze
  REASONS = %w[STALE CONTRADICTED SUPERSEDED DUPLICATE ONE-OFF NEGATIVE-CLAIM TOO-NARROW MERGED DECAYED].freeze
  EXTERNAL = %w[Enum Kernel Code Mix ExUnit String Map MapSet Keyword List Process GenServer Supervisor Task Phoenix Ecto Jason Req Plug File Path System IO Logger Application Registry DynamicSupervisor :erlang :ets].freeze
  Error = Class.new(StandardError)

  def self.fail_validation(message)
    raise Error, message
  end

  # Keep identical to the validator: digest only content following the anchor.
  def self.canonical_entry(lines)
    content = lines.join
    content = content.sub(/\A\n+/, "")
    content = content.rstrip
    fail_validation("entry content is empty") if content.empty?
    fail_validation("entry does not preserve its bold heading") unless content.start_with?("**")
    "#{content}\n"
  end

  def self.title_words(title)
    stopwords = %w[a an and are as at be by for from in is it of on or that the this to with]
    title.downcase.scan(/[[:alnum:]]{3,}/).reject { |word| stopwords.include?(word) }.to_set
  end

  def self.jaccard(left, right)
    union = left | right
    union.empty? ? 0.0 : (left & right).length.to_f / union.length
  end

  # Python json.dump(indent=2, ensure_ascii=False), including compact empty
  # containers. Hash insertion order preserves all existing inventory keys.
  def self.json(value, depth = 0)
    indent = "  " * depth
    child_indent = "  " * (depth + 1)
    case value
    when Hash
      return "{}" if value.empty?
      "{\n" + value.map { |key, item| "#{child_indent}#{JSON.generate(key)}: #{json(item, depth + 1)}" }.join(",\n") + "\n#{indent}}"
    when Array
      return "[]" if value.empty?
      "[\n" + value.map { |item| "#{child_indent}#{json(item, depth + 1)}" }.join(",\n") + "\n#{indent}]"
    else
      JSON.generate(value)
    end
  end

  def self.date(value)
    raise Error, "invalid date: #{value.inspect}" unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    Date.iso8601(value)
  rescue ArgumentError
    raise Error, "invalid date: #{value.inspect}"
  end

  def self.blocks(text)
    lines = text.lines
    markers = lines.each_index.map do |index|
      match = lines[index].match(/\A<!-- applied-learning: ([a-z0-9-]+) -->\n?\z/)
      [index, match[1]] if match
    end.compact
    markers.each_with_index.map do |(start, slug), index|
      finish = markers[index + 1]&.first || lines.length
      anchor = "<a id=\"applied-learning-#{slug}\"></a>\n"
      raise Error, "#{slug}: missing anchor" unless lines[start + 1] == anchor
      {slug: slug, start: start, finish: finish, content: canonical_entry(lines[(start + 2)...finish]),
       block: lines[start...finish].join}
    end
  end

  class Corpus
    attr_reader :root, :inventory, :files

    def initialize(root)
      @root = File.realpath(root)
      @files = {}
      @inventory = JSON.parse(read(INVENTORY))
    end

    def path(relative)
      raise Error, "unsafe repository path: #{relative.inspect}" unless relative.is_a?(String) &&
        !relative.empty? && !relative.start_with?("/") && !relative.include?("..")
      full = File.join(root, relative)
      ancestor = full
      ancestor = File.dirname(ancestor) until File.exist?(ancestor) || File.symlink?(ancestor)
      real = File.realpath(ancestor)
      raise Error, "path escapes repository: #{relative}" unless real == root || real.start_with?(root + "/")
      full
    end

    def read(relative)
      @files[relative] ||= File.read(path(relative), encoding: "UTF-8")
    end

    def entries
      inventory.fetch("entries")
    end

    def live
      entries.select { |entry| entry["status"] == "live" }
    end

    def entry(slug)
      entries.find { |entry| entry["slug"] == slug } || raise(Error, "unknown slug: #{slug}")
    end

    def live_entry(slug)
      found = entry(slug)
      raise Error, "#{slug}: entry is not live" unless found["status"] == "live"
      found
    end

    def block(entry)
      AppliedLearningReview.blocks(read(entry.fetch("destination"))).find { |item| item[:slug] == entry["slug"] } ||
        raise(Error, "#{entry["slug"]}: missing entry block")
    end

    def content(entry)
      block(entry).fetch(:content)
    end

    def replace_block(entry, replacement)
      destination = entry.fetch("destination")
      lines = read(destination).lines
      owned = block(entry)
      before = lines[0...owned[:start]].join.rstrip
      after = lines[owned[:finish]..-1].join.sub(/\A\n+/, "").rstrip
      parts = [before, replacement&.rstrip, after].compact.reject(&:empty?)
      @files[destination] = parts.join("\n\n") + "\n"
    end

    def replace_content(entry, text, title = nil)
      content = AppliedLearningReview.canonical_entry([text])
      heading = content.match(/\A\*\*(.+?)\*\*/m)
      raise Error, "#{entry["slug"]}: missing bold title" unless heading
      extracted_title = heading[1].split.join(" ")
      raise Error, "#{entry["slug"]}: title does not match bold text" if title && title != extracted_title
      replacement = "<!-- applied-learning: #{entry["slug"]} -->\n<a id=\"#{entry["anchor"]}\"></a>\n#{content}"
      replace_block(entry, replacement)
      entry["title"] = extracted_title
      entry["content_sha256"] = Digest::SHA256.hexdigest(content)
    end

    def retire(slug, reason, today, superseded_by = nil)
      item = live_entry(slug)
      raise Error, "#{slug}: refusing to retire an always-loaded entry" if item["always_loaded"]
      raise Error, "#{slug}: invalid retirement reason" unless REASONS.include?(reason)
      raise Error, "#{slug}: MERGED requires superseded_by" if reason == "MERGED" && superseded_by.nil?
      live_entry(superseded_by) if superseded_by
      raise Error, "#{slug}: cannot supersede itself" if superseded_by == slug
      archive = "#{inventory.fetch("archive_root")}/#{item.fetch("topic")}.md"
      path(archive)
      block_text = block(item).fetch(:block).rstrip
      replace_block(item, nil)
      preamble = "# Applied Learning archive: #{item["topic"]}\n\nRetired entries, kept for history and revival. Not loaded by default.\n\n"
      existing = @files[archive] || (File.exist?(path(archive)) ? read(archive) : preamble)
      @files[archive] = existing.rstrip + "\n\n" + block_text + "\n"
      item["status"] = "retired"
      item["destination"] = archive
      item["retired_on"] = today.to_s
      item["retired_reason"] = reason
      item["superseded_by"] = superseded_by
    end

    def update_fields(item, row, fields)
      fields.each { |field| item[field] = row[field] if row.key?(field) }
    end

    def apply_row(row, today, review_date)
      case row.fetch("action")
      when "retire"
        retire(row.fetch("slug"), row.fetch("reason"), today, row["superseded_by"])
      when "merge"
        item = live_entry(row.fetch("survivor"))
        text = row.fetch("text")
        raise Error, "merge requires text starting with **" unless text.is_a?(String) && text.start_with?("**")
        retired = row.fetch("retire")
        raise Error, "merge retire must be a nonempty array excluding survivor" unless retired.is_a?(Array) &&
          !retired.empty? && !retired.include?(item["slug"]) && retired.uniq == retired
        replace_content(item, text, row["title"])
        update_fields(item, row, %w[class scope revisit_when])
        item["last_confirmed"] = today.to_s
        item["confirmed_by"] = row["confirmed_by"] || "review-#{review_date}"
        retired.each { |slug| retire(slug, "MERGED", today, item["slug"]) }
      when "rewrite"
        item = live_entry(row.fetch("slug"))
        replace_content(item, row.fetch("text"), row["title"])
        update_fields(item, row, %w[class scope revisit_when])
        item["last_confirmed"] = today.to_s
      when "reconfirm"
        item = live_entry(row.fetch("slug"))
        item["last_confirmed"] = today.to_s
        item["confirmed_by"] = row["confirmed_by"] || "review-#{review_date}"
      when "reclassify"
        item = live_entry(row.fetch("slug"))
        raise Error, "reclassify requires class and/or scope" unless row.key?("class") || row.key?("scope")
        update_fields(item, row, %w[class scope])
      when "add"
        add(row, today)
      when "move"
        move(row)
      else
        raise Error, "unsupported action: #{row["action"]}"
      end
    end

    # Relocate a live entry, byte-for-byte, to another existing live corpus file
    # (used to split an oversized topic file). The digest is unchanged.
    def move(row)
      item = live_entry(row.fetch("slug"))
      destination = row.fetch("destination")
      raise Error, "move destination must be a live skill file" unless
        destination.match?(%r{\A\.claude/skills/(?:[^/]+/)*[^/]+\.md\z})
      raise Error, "move destination cannot be the archive" if destination.start_with?(inventory.fetch("archive_root") + "/")
      raise Error, "#{item["slug"]}: refusing to move an always-loaded entry" if item["always_loaded"]
      raise Error, "#{item["slug"]}: already in #{destination}" if item["destination"] == destination
      raise Error, "move destination must already exist: #{destination}" unless
        @files.key?(destination) || File.exist?(path(destination))
      block_text = block(item).fetch(:block).rstrip
      replace_block(item, nil)
      if row["after"]
        previous = live_entry(row["after"])
        raise Error, "after entry must belong to destination" unless previous["destination"] == destination
        replace_block(previous, block(previous).fetch(:block).rstrip + "\n\n" + block_text)
      else
        @files[destination] = read(destination).rstrip + "\n\n" + block_text + "\n"
      end
      item["destination"] = destination
    end

    def add(row, today)
      slug = row.fetch("slug")
      raise Error, "invalid or existing slug: #{slug}" unless slug.is_a?(String) && slug.match?(/\A[a-z0-9][a-z0-9-]*\z/) &&
        entries.none? { |item| item["slug"] == slug }
      destination = row.fetch("destination")
      raise Error, "add destination must be a live corpus file" unless destination == "CLAUDE.md" ||
        destination.match?(%r{\A\.claude/skills/(?:[^/]+/)*[^/]+\.md\z})
      archive_root = inventory.fetch("archive_root")
      raise Error, "add destination cannot be the archive" if destination.start_with?(archive_root + "/")
      content = AppliedLearningReview.canonical_entry([row.fetch("text")])
      title = content.match(/\A\*\*(.+?)\*\*/m)
      raise Error, "add requires a bold title" unless title
      item = {"source_ordinal" => entries.map { |entry| entry.fetch("source_ordinal") }.max + 1,
              "source_kind" => "post-migration", "slug" => slug, "title" => title[1].split.join(" "),
              "topic" => row.fetch("topic"), "class" => row.fetch("class"), "status" => "live",
              "destination" => destination, "anchor" => "applied-learning-#{slug}", "created" => today.to_s,
              "source_session" => row.fetch("source_session"), "source_incident" => row.fetch("source_incident"),
              "scope" => row.fetch("scope"), "last_confirmed" => nil, "confirmed_by" => nil,
              "revisit_when" => row.fetch("revisit_when"), "content_sha256" => Digest::SHA256.hexdigest(content),
              "always_loaded" => false}
      block_text = "<!-- applied-learning: #{slug} -->\n<a id=\"#{item["anchor"]}\"></a>\n#{content}"
      existing = read(destination)
      if row["after"]
        previous = live_entry(row["after"])
        raise Error, "after entry must belong to destination" unless previous["destination"] == destination
        replace_block(previous, block(previous).fetch(:block).rstrip + "\n\n" + block_text)
      else
        @files[destination] = existing.rstrip + "\n\n" + block_text
      end
      entries << item
      inventory["entry_count"] += 1
      inventory["post_migration_entry_count"] += 1
    end
  end

  class Review
    attr_reader :corpus, :today, :notes, :sources, :usage, :rows

    def initialize(corpus, today)
      @corpus, @today = corpus, today
      @notes = []
      @sources = {"claude_sessions" => 0, "codex_sessions" => 0, "hook_events" => 0, "commits" => 0}
      @citations = {}
      @exposures = {}
      @ranges = {}
      corpus.entries.map { |entry| entry["destination"] }.uniq.sort.each do |destination|
        @ranges[destination] = AppliedLearningReview.blocks(corpus.read(destination))
      end
      @titles = corpus.live.to_h { |entry| [entry["slug"], AppliedLearningReview.title_words(entry["title"])] }
    end

    def day(value)
      Date.iso8601(value.to_s[0, 10])
    rescue ArgumentError
      nil
    end

    def within_window?(date)
      date && date >= today - 90 && date <= today
    end

    def cite(text, session, date)
      return unless date && date <= today
      text.scan(CITATION).each do |slug, confirmation|
        key = [slug, session, date.to_s]
        @citations[key] = !!confirmation || @citations.fetch(key, false)
      end
    end

    def expose(destination, first, last, session, date)
      return unless within_window?(date)
      @ranges.fetch(destination, []).each do |block|
        next if last && block[:start] + 1 > last
        next if block[:finish] < first
        @exposures[[block[:slug], session]] = true
      end
    end

    def paths_in(text)
      # Recognize relative and absolute paths, including quoted paths inside JS
      # and JSON tool wrappers. Match against current destinations, never outputs.
      text.scan(%r{(?:[^\s"'`\\<>;()\[\]{},=]+/)?applied-learning-[a-z0-9-]+\.md}).flat_map do |path|
        @ranges.keys.select { |destination| path == destination || path.end_with?("/" + destination) ||
          (File.basename(path) == path && File.basename(destination) == path) }
      end.uniq
    end

    def tool_input(name, input, session, date)
      return if name.to_s.match?(/apply_patch/) || input.to_s.include?("*** Begin Patch")
      if input.is_a?(String)
        begin
          parsed = JSON.parse(input)
          return tool_input(name, parsed, session, date) if parsed.is_a?(Hash)
        rescue JSON::ParserError
          # Codex custom calls are raw command/JS strings.
        end
      end
      if input.is_a?(Hash)
        file = input["file_path"] || input["path"]
        command = input["command"] || input["cmd"] || input["code"]
        if file.is_a?(String)
          first = [input.fetch("offset", 1).to_i, 1].max
          last = input["limit"] ? first + input["limit"].to_i - 1 : nil
          first, last = 1, nil if name.to_s.match?(/grep/i)
          paths_in(file).each { |destination| expose(destination, first, last, session, date) }
        end
        return command_exposures(command, session, date) if command.is_a?(String)
        # Function wrappers may carry nested command objects.
        input.each_value { |value| tool_input(name, value, session, date) if value.is_a?(Hash) || value.is_a?(Array) }
      elsif input.is_a?(Array)
        input.each { |value| tool_input(name, value, session, date) }
      elsif input.is_a?(String)
        command_exposures(input, session, date)
      end
    end

    def command_exposures(command, session, date)
      # Codex can batch several exec_command calls inside one JS tool input.
      # Read each command string independently before interpreting its ranges.
      embedded = command.scan(/["']?(?:cmd|command)["']?\s*:\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')/m).flatten
      unless embedded.empty?
        embedded.each do |literal|
          decoded = if literal.start_with?('"')
            begin
              JSON.parse(literal)
            rescue JSON::ParserError
              literal[1...-1]
            end
          else
            literal[1...-1].gsub(/\\(['\\])/, '\1')
          end
          command_exposures(decoded, session, date)
        end
        return
      end
      # Split independent shell commands and embedded command strings so a sed
      # range doesn't accidentally constrain another file read in the same call.
      command.split(/;|\n|&&|\|\|/).each do |part|
        next if part.include?("*** Begin Patch")
        first, last = 1, nil
        if (match = part.match(/\bsed\s+-n\s+["']?(\d+)(?:,(\d+|\$))?p/))
          first = match[1].to_i
          last = match[2] == "$" ? nil : (match[2] || match[1]).to_i
        elsif (match = part.match(/\bhead\s+-n\s*(\d+)/))
          last = match[1].to_i
        end
        paths_in(part).each { |destination| expose(destination, first, last, session, date) }
      end
    end

    def jsonl(path)
      malformed = 0
      File.foreach(path, encoding: "UTF-8") do |line|
        begin
          event = JSON.parse(line)
          yield event if event.is_a?(Hash)
        rescue JSON::ParserError
          malformed += 1
        end
      end
      notes << "Skipped #{malformed} malformed JSONL lines in #{File.basename(path)}." if malformed > 0
    rescue Errno::ENOENT, Errno::EACCES => error
      notes << "Skipped unavailable source #{path}: #{error.class}."
    end

    def text_content(content)
      case content
      when String then content
      when Array then content.map { |block| block.is_a?(Hash) ? block["text"].to_s : "" }.join("\n")
      else ""
      end
    end

    def harvest_claude(glob)
      paths = Dir.glob(File.expand_path(glob)).sort
      notes << "Missing Claude sources: #{glob}." if paths.empty?
      paths.each do |path|
        session = nil
        seen = false
        jsonl(path) do |event|
          session = "claude:#{event["sessionId"]}" if event["sessionId"]
          session ||= "claude:#{event["sessionId"] || File.basename(path, ".jsonl")}"
          seen = true
          next unless event["type"] == "assistant"
          date = day(event["timestamp"])
          content = event.fetch("message", {}).fetch("content", [])
          cite(text_content(content), session, date)
          Array(content).each do |block|
            next unless block.is_a?(Hash) && block["type"] == "tool_use"
            next unless %w[Read Bash Grep].include?(block["name"])
            tool_input(block["name"], block["input"], session, date)
          end
        end
        sources["claude_sessions"] += 1 if seen
      end
    end

    def harvest_codex(glob)
      paths = Dir.glob(File.expand_path(glob)).sort
      notes << "Missing Codex sources: #{glob}." if paths.empty?
      paths.each do |path|
        meta = nil
        # Select using the first session_meta only, before harvesting any events.
        File.foreach(path, encoding: "UTF-8") do |line|
          begin
            event = JSON.parse(line)
            next unless event["type"] == "session_meta"
            meta = event["payload"] || event
            break
          rescue JSON::ParserError
            next
          end
        end
        next unless meta && (meta["cwd"].to_s.include?("trust-arbor") || meta["cwd"].to_s.match?(%r{/\.codex/worktrees/[^/]+/arbor(?:/|\z)}))
        sources["codex_sessions"] += 1
        session = "codex:#{meta["id"] || meta["session_id"] || File.basename(path, ".jsonl")}"
        jsonl(path) do |event|
          payload = event["payload"].is_a?(Hash) ? event["payload"] : event
          date = day(event["timestamp"] || payload["timestamp"])
          case payload["type"]
          when "message"
            cite(text_content(payload["content"]), session, date) if payload["role"] == "assistant"
          when "agent_message"
            cite(text_content(payload["content"] || payload["message"] || payload["text"]), session, date)
          when "custom_tool_call", "function_call"
            tool_input(payload["name"], payload["input"] || payload["arguments"], session, date)
          end
        end
      rescue Errno::ENOENT, Errno::EACCES => error
        notes << "Skipped unavailable Codex source #{path}: #{error.class}."
      end
    end

    def harvest_hooks
      path = corpus.path(".claude/state/al-exposure.jsonl")
      unless File.exist?(path)
        notes << "Missing exposure log: .claude/state/al-exposure.jsonl."
        return
      end
      jsonl(path) do |event|
        sources["hook_events"] += 1
        next if event["session_id"].to_s.empty?
        tool_input(event["tool_name"], event["tool_input"], "claude:#{event["session_id"]}", day(event["ts"]))
      end
    end

    def harvest_git
      output, error, status = Open3.capture3("git", "-C", corpus.root, "log", "--since=#{today - 120}",
        "--format=%H%x00%aI%x00%B%x00")
      unless status.success?
        notes << "Git source unavailable: #{error.lines.first.to_s.strip}."
        return
      end
      output.split("\0").each_slice(3) do |sha, timestamp, message|
        next unless message
        sources["commits"] += 1
        cite(message, "git:#{sha.strip}", day(timestamp))
      end
    rescue Errno::ENOENT
      notes << "Git source unavailable: git executable missing."
    end

    def build_usage
      live = corpus.live.sort_by { |entry| entry["slug"] }
      by_slug = live.to_h { |entry| [entry["slug"], entry] }
      broken = @citations.keys.group_by(&:first).reject { |slug, _| by_slug.key?(slug) }.sort.map do |slug, keys|
        {"slug" => slug, "count" => keys.length, "last_seen" => keys.map(&:last).max}
      end
      @usage = {"generated_on" => today.to_s, "window_days" => 90, "sources" => sources,
                "broken_citations" => broken, "entries" => {}}
      citations_by_slug = @citations.group_by { |key, _confirmation| key.first }
      exposures_by_slug = @exposures.keys.group_by(&:first)
      live.each do |entry|
        slug = entry["slug"]
        citations = citations_by_slug.fetch(slug, [])
        recent = citations.select { |key, _| within_window?(day(key.last)) }
        relearned = live.count do |other|
          other["created"] > entry["created"] && within_window?(AppliedLearningReview.date(other["created"])) &&
            AppliedLearningReview.jaccard(@titles.fetch(slug), @titles.fetch(other["slug"])) >= 0.5
        end
        exposure_count = exposures_by_slug.fetch(slug, []).length
        confirmation_count = recent.count { |_key, confirmation| confirmation }
        score = 3 * recent.length + 2 * relearned + 2 * confirmation_count +
          (entry["class"] == "security-invariant" ? 1 : 0) - (exposure_count >= 10 && recent.empty? ? 1 : 0)
        usage["entries"][slug] = {"exposures_90d" => exposure_count, "citations_90d" => recent.length,
          "citations_total" => citations.length, "last_cited" => citations.map { |key, _| key.last }.max,
          "confirmations_90d" => confirmation_count, "relearned" => relearned, "score" => score}
      end
    end

    def source_files
      @source_files ||= %w[apps config clients bin mix.exs].flat_map do |relative|
        full = corpus.path(relative)
        File.directory?(full) ? Dir.glob(File.join(full, "**", "*")) : [full]
      end.select { |path| File.file?(path) && !File.symlink?(path) && !path.match?(%r{/(?:deps|_build|node_modules|\.git)/}) }.sort
    end

    def source_texts
      @source_texts ||= source_files.map do |path|
        text = File.read(path, encoding: "UTF-8")
        text if text.valid_encoding? && !text.include?("\0")
      rescue Errno::EACCES, Errno::ENOENT
        nil
      end.compact
    end

    def literal_hit?(anchor)
      paths = %w[apps config clients bin mix.exs].select { |relative| File.exist?(corpus.path(relative)) }
      return false if paths.empty?
      _output, _error, status = Open3.capture3("rg", "-F", "-q", "--", anchor, *paths, chdir: corpus.root)
      return true if status.success?
      return false if status.exitstatus == 1
      source_texts.any? { |text| text.include?(anchor) }
    rescue Errno::ENOENT
      source_texts.any? { |text| text.include?(anchor) }
    end

    def anchor_exists?(anchor)
      @anchor_cache ||= {}
      return @anchor_cache[anchor] if @anchor_cache.key?(anchor)
      external = EXTERNAL.any? { |prefix| anchor == prefix || anchor.start_with?(prefix + ".") || anchor.start_with?(prefix + "/") }
      found = if external
        true
      elsif anchor.match?(%r{\A(?:apps|config|clients|bin|docs|\.claude|scripts|packages|images)/})
        # Scope anchors are evidence, not write destinations: normalize benign
        # parent segments and treat escaping/example paths as misses.
        full = File.expand_path(anchor, corpus.root)
        full.start_with?(corpus.root + "/") && !Dir.glob(full).empty?
      elsif (match = anchor.match(/\A(.+)\.([a-z_][a-z0-9_!?]*)\/\d+\z/))
        literal_hit?("#{match[1]}.#{match[2]}") || source_texts.any? do |text|
          text.match?(/\bdefmodule\s+(?:[A-Z]\w*\.)*#{Regexp.escape(match[1])}\b/) &&
            text.match?(/\bdefp?\s+#{Regexp.escape(match[2])}(?=[\s(,]|$)/)
        end
      else
        literal_hit?(anchor)
      end
      @anchor_cache[anchor] = found
    end

    def row(action, fields)
      @rows << {"id" => "#{today}-#{@rows.length + 1}", "action" => action}.merge(fields).merge("decision" => "pending")
    end

    def shingles(content)
      content.downcase.scan(/[a-z0-9]+/).each_cons(5).map { |words| words.join(" ") }.to_set
    end

    def build_rows
      @rows = []
      live = corpus.live.sort_by { |entry| entry["slug"] }
      live.each do |entry|
        stats = usage["entries"].fetch(entry["slug"])
        age = (today - AppliedLearningReview.date(entry["created"])).to_i
        last_confirmed = entry["last_confirmed"] && AppliedLearningReview.date(entry["last_confirmed"])
        if !entry["always_loaded"] && entry["class"] != "security-invariant" && age >= 90 &&
            stats["citations_90d"] == 0 && stats["relearned"] == 0 && (!last_confirmed || last_confirmed < today - 90)
          row("retire", {"slug" => entry["slug"], "reason" => "DECAYED", "evidence" =>
            ["Age #{age} days; no citations or relearning in 90 days; no confirmation in 90 days."], "score" => stats["score"]})
        end
        anchors = entry.fetch("scope") + entry["revisit_when"].to_s.scan(/`([^`]+)`/).flatten
        misses = anchors.uniq.reject { |anchor| anchor_exists?(anchor) }
        unless misses.empty?
          row("reconfirm", {"slug" => entry["slug"], "reason" => "STALE", "evidence" =>
            misses.map { |anchor| "Missing anchor: #{anchor}" } +
              ["re-verify; change to retire+STALE/CONTRADICTED or rewrite if wrong"], "score" => stats["score"]})
        end
      end
      pairs = 0
      body_sets = {}
      live.group_by { |entry| entry["topic"] }.sort.each do |_topic, members|
        members.combination(2) do |left, right|
          break if pairs >= 50
          title_similarity = AppliedLearningReview.jaccard(@titles[left["slug"]], @titles[right["slug"]])
          shared = left["scope"] & right["scope"]
          body_similarity = 0.0
          if title_similarity < 0.5 && !shared.empty?
            [left, right].each { |entry| body_sets[entry["slug"]] ||= shingles(corpus.content(entry)) }
            body_similarity = AppliedLearningReview.jaccard(body_sets[left["slug"]], body_sets[right["slug"]])
          end
          next unless title_similarity >= 0.5 || (!shared.empty? && body_similarity >= 0.2)
          ranked = [left, right].sort_by { |entry| [usage["entries"][entry["slug"]]["score"], entry["created"], entry["slug"]] }.reverse
          survivor, other = ranked.map { |entry| entry["slug"] }
          row("merge", {"survivor" => survivor, "members" => [survivor, other], "retire" => [other], "text" => nil,
            "reason" => "MERGED", "evidence" => ["Title Jaccard #{format('%.3f', title_similarity)}; body shingle Jaccard #{format('%.3f', body_similarity)}; shared scope: #{shared.join(', ')}"],
            "score" => usage["entries"][survivor]["score"]})
          pairs += 1
        end
      end
      already_retiring = rows.select { |item| item["action"] == "retire" }.map { |item| item["slug"] }.to_set
      live.group_by { |entry| entry["destination"] }.sort.each do |destination, members|
        next unless destination.match?(%r{\A\.claude/skills/applied-learning-[^/]+\.md\z})
        words = members.to_h { |entry| [entry["slug"], corpus.content(entry).split.length] }
        total = words.values.sum
        next unless total > 8_000
        total -= members.select { |entry| already_retiring.include?(entry["slug"]) }.sum { |entry| words[entry["slug"]] }
        members.reject { |entry| entry["always_loaded"] || entry["class"] == "security-invariant" || already_retiring.include?(entry["slug"]) }
          .sort_by { |entry| [usage["entries"][entry["slug"]]["score"], entry["slug"]] }.each do |entry|
          break if total <= 8_000
          row("retire", {"slug" => entry["slug"], "reason" => "DECAYED", "cap" => true,
            "evidence" => ["#{destination}: #{total} live words before removing #{words[entry["slug"]]} words; cap 8,000."],
            "score" => usage["entries"][entry["slug"]]["score"]})
          total -= words[entry["slug"]]
          already_retiring << entry["slug"]
        end
      end
    end

    def summary
      stats = usage.fetch("entries").values
      "live=#{stats.length} claude_sessions=#{sources['claude_sessions']} codex_sessions=#{sources['codex_sessions']} " +
        "hook_events=#{sources['hook_events']} commits=#{sources['commits']} exposures_90d=#{stats.sum { |item| item['exposures_90d'] }} " +
        "citations_90d=#{stats.sum { |item| item['citations_90d'] }} broken_citations=#{usage['broken_citations'].length} " +
        "proposals=#{rows.length} actions=#{rows.group_by { |item| item['action'] }.transform_values(&:length)}"
    end

    def markdown
      escape = ->(value) { value.to_s.gsub("|", "\\|").gsub("\n", " ") }
      lines = ["# Applied Learning review: #{today}", "", summary, "", "## How to approve", "",
        "Edit `decision` in the companion decisions JSON to `approve` or `reject`. Fill in merge `text` (starting with `**`) before approval.",
        "Run `ruby .claude/applied_learning_review.rb --apply <decisions.json> --dry-run`, then repeat without `--dry-run` to apply approved rows.", "",
        "## Sources", ""] + notes.map { |note| "- #{note}" }
      rows.group_by { |item| item["action"] }.sort.each do |action, items|
        lines += ["", "## #{action}", "", "| ID | Entry / members | Reason | Score | Evidence | Decision |", "| --- | --- | --- | ---: | --- | --- |"]
        items.each do |item|
          label = item["slug"] || "#{item['survivor']} ← #{item['retire'].join(', ')}"
          lines << "| #{item['id']} | #{escape.call(label)} | #{item['reason']} | #{item['score']} | #{escape.call(item['evidence'].join('; '))} | pending |"
        end
      end
      lines += ["", "## Broken citations", "", "| Slug | Count | Last seen |", "| --- | ---: | --- |"]
      usage["broken_citations"].each { |item| lines << "| #{item['slug']} | #{item['count']} | #{item['last_seen']} |" }
      lines << "None." if usage["broken_citations"].empty?
      lines.join("\n") + "\n"
    end
  end

  def self.apply(corpus, path, today, dry_run)
    decisions = JSON.parse(File.read(path, encoding: "UTF-8"))
    review_date = decisions.fetch("review_date")
    date(review_date)
    approved, skipped = decisions.fetch("rows").partition { |row| row["decision"] == "approve" }
    skipped.each { |row| puts "Skipped #{row['id'] || row['action']}: #{row['decision'] || 'pending'}" }
    approved.each { |row| corpus.apply_row(row, today, review_date) }
    corpus.files[INVENTORY] = json(corpus.inventory) + "\n"
    changes = corpus.files.select { |relative, content| !File.exist?(corpus.path(relative)) || File.binread(corpus.path(relative)) != content.b }
    puts "#{dry_run ? 'Would touch' : 'Files touched'}: #{changes.keys.sort.join(', ')}"
    if dry_run
      approved.each { |row| puts "Would apply #{row['id'] || row['action']}: #{row['action']} #{row['slug'] || row['survivor']}" }
      return
    end
    originals = changes.to_h { |relative, _| [relative, File.exist?(corpus.path(relative)) ? File.binread(corpus.path(relative)) : nil] }
    created_dirs = []
    begin
      changes.each do |relative, content|
        destination = corpus.path(relative)
        directory = File.dirname(destination)
        until File.directory?(directory)
          created_dirs << directory
          directory = File.dirname(directory)
        end
        FileUtils.mkdir_p(File.dirname(destination))
        File.binwrite(destination, content)
      end
      output, error, status = Open3.capture3(RbConfig.ruby, corpus.path(".claude/validate_applied_learning.rb"), chdir: corpus.root)
      $stdout.write(output)
      $stderr.write(error)
      raise Error, "validator failed; restored every touched file byte-for-byte" unless status.success?
    rescue StandardError
      originals.each do |relative, content|
        destination = corpus.path(relative)
        content.nil? ? FileUtils.rm_f(destination) : File.binwrite(destination, content)
      end
      created_dirs.uniq.sort_by(&:length).reverse_each { |directory| Dir.rmdir(directory) if File.directory?(directory) && Dir.empty?(directory) }
      raise
    end
    approved.each { |row| puts "Applied #{row['id'] || row['action']}: #{row['action']} #{row['slug'] || row['survivor']}" }
    puts "Applied #{approved.length}; skipped #{skipped.length}."
  end

  def self.run(argv)
    options = {root: File.expand_path("..", __dir__), today: Date.today,
      claude_glob: "~/.claude/projects/*trust-arbor*/**/*.jsonl", codex_glob: "~/.codex/sessions/**/*.jsonl"}
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby .claude/applied_learning_review.rb [--report | --apply PATH [--dry-run]]"
      opts.on("--root DIR") { |value| options[:root] = File.expand_path(value) }
      opts.on("--today YYYY-MM-DD") { |value| options[:today] = date(value) }
      opts.on("--claude-glob GLOB") { |value| options[:claude_glob] = value }
      opts.on("--codex-glob GLOB") { |value| options[:codex_glob] = value }
      opts.on("--report") { options[:report] = true }
      opts.on("--out-dir DIR") { |value| options[:out_dir] = File.expand_path(value) }
      opts.on("--apply PATH") { |value| options[:apply] = value }
      opts.on("--dry-run") { options[:dry_run] = true }
      opts.on("-h", "--help") { puts opts; return }
    end
    parser.parse!(argv)
    raise Error, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?
    raise Error, "--report and --apply are mutually exclusive" if options[:report] && options[:apply]
    raise Error, "--dry-run requires --apply" if options[:dry_run] && !options[:apply]
    corpus = Corpus.new(options[:root])
    if options[:apply]
      apply(corpus, options[:apply], options[:today], options[:dry_run])
    else
      review = Review.new(corpus, options[:today])
      review.harvest_claude(options[:claude_glob])
      review.harvest_codex(options[:codex_glob])
      review.harvest_hooks
      review.harvest_git
      review.build_usage
      review.build_rows
      out_dir = options[:out_dir] || corpus.path(".arbor/roadmap/0-inbox")
      FileUtils.mkdir_p(out_dir)
      prefix = File.join(out_dir, "applied-learning-review-#{options[:today]}")
      File.write(corpus.path(USAGE), json(review.usage) + "\n", encoding: "UTF-8")
      File.write(prefix + ".md", review.markdown, encoding: "UTF-8")
      File.write(prefix + "-decisions.json", json({"review_date" => options[:today].to_s,
        "generated_by" => ".claude/applied_learning_review.rb", "rows" => review.rows}) + "\n", encoding: "UTF-8")
      puts review.summary
      puts "Wrote #{USAGE}, #{prefix}.md, #{prefix}-decisions.json"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    AppliedLearningReview.run(ARGV)
  rescue AppliedLearningReview::Error, OptionParser::ParseError, JSON::ParserError, KeyError, TypeError, SystemCallError => error
    warn "Applied Learning review: FAIL: #{error.message}"
    exit 1
  end
end

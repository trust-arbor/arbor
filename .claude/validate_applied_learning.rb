#!/usr/bin/env ruby

# Single authority for Applied Learning accounting, admission, and budgets.

require "digest"
require "json"
require "date"
require "set"

ROOT = File.expand_path("..", __dir__)
INVENTORY_PATH = File.join(ROOT, ".claude", "skills", "applied-learning-inventory.json")

def fail_validation(message)
  warn "Applied Learning validation: FAIL: #{message}"
  exit 1
end

def read_required(path)
  # Read as UTF-8 explicitly. Ruby otherwise uses the locale default, and the
  # pre-commit hook runs without one — so every regexp against this corpus
  # raised `invalid byte sequence in US-ASCII` on the first em dash, blocking
  # any commit that touches .claude/. It only surfaced when those files
  # changed, which is why it went unnoticed.
  File.read(path, encoding: "UTF-8")
rescue Errno::ENOENT
  fail_validation("missing file #{path.delete_prefix(ROOT + "/")}")
end

def canonical_entry(lines)
  content = lines.join
  content = content.sub(/\A\n+/, "")
  content = content.rstrip
  fail_validation("entry content is empty") if content.empty?
  fail_validation("entry does not preserve its bold heading") unless content.start_with?("**")
  "#{content}\n"
end

def date?(value)
  value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/) && Date.iso8601(value)
rescue ArgumentError
  false
end

def title_words(title)
  stopwords = %w[a an and are as at be by for from in is it of on or that the this to with]
  title.downcase.scan(/[[:alnum:]]{3,}/).reject { |word| stopwords.include?(word) }.to_set
end

def jaccard(left, right)
  union = left | right
  union.empty? ? 0.0 : (left & right).length.to_f / union.length
end

def warn_validation(message, enforced = false)
  fail_validation(message) if enforced
  warn "Applied Learning validation: WARN: #{message}"
end

inventory = JSON.parse(read_required(INVENTORY_PATH))
fail_validation("schema_version must be 2") unless inventory["schema_version"] == 2
fail_validation("admission_cutover must be a date") unless date?(inventory["admission_cutover"])
archive_root = inventory["archive_root"]
fail_validation("archive_root must be a repository-relative directory") unless
  archive_root.is_a?(String) && !archive_root.empty? && !archive_root.start_with?("/") &&
    !archive_root.include?("..") && !archive_root.end_with?("/")
entries = inventory.fetch("entries")
expected_count = inventory.fetch("entry_count")
fail_validation("entry_count does not match inventory") unless expected_count == entries.length
fail_validation("inventory source is not CLAUDE.md Applied Learning") unless
  inventory.fetch("source_file") == "CLAUDE.md" && inventory.fetch("source_section") == "Applied Learning"
original_entries = entries.reject { |entry| entry.fetch("source_kind", "original") == "post-migration" }
fail_validation("original entry count changed") unless original_entries.length == inventory.fetch("original_entry_count")
fail_validation("original source ordinals are not complete") unless
  original_entries.map { |entry| entry.fetch("source_ordinal") }.sort == (1..inventory.fetch("original_entry_count")).to_a
post_migration_entries = entries.select { |entry| entry.fetch("source_kind", "original") == "post-migration" }
fail_validation("post-migration entry count changed") unless post_migration_entries.length == inventory.fetch("post_migration_entry_count")

required_topics = %w[
  acp-mcp
  shell-containment
  testing-live-runtime
  otp-ownership-cleanup
  persistence-database
  providers-oauth
  council-review
  filesystem-git
]

slugs = entries.map { |entry| entry.fetch("slug") }
fail_validation("inventory contains duplicate slugs") unless slugs.uniq.length == slugs.length
fail_validation("missing required topics") unless required_topics.all? { |topic| entries.any? { |entry| entry.fetch("topic") == topic } }
fail_validation("always-loaded working set must contain exactly 12 entries") unless
  entries.count { |entry| entry.fetch("always_loaded") } == 12
fail_validation("always-loaded entries must target CLAUDE.md") unless
  entries.select { |entry| entry.fetch("always_loaded") }.all? { |entry| entry.fetch("destination") == "CLAUDE.md" }

destination_paths = entries.map { |entry| entry.fetch("destination") }.uniq
destination_paths.each do |relative_path|
  fail_validation("destination escapes repository: #{relative_path}") if relative_path.start_with?("/") || relative_path.include?("..")
  read_required(File.join(ROOT, relative_path))
end

candidate_paths = (["CLAUDE.md"] +
  Dir.glob(File.join(ROOT, ".claude", "skills", "**", "*.md")) +
  Dir.glob(File.join(ROOT, archive_root, "*.md"))).map { |path| path.delete_prefix(ROOT + "/") }.uniq.sort
corpus_files = candidate_paths.to_h { |relative_path| [relative_path, read_required(File.join(ROOT, relative_path))] }
found = Hash.new { |hash, slug| hash[slug] = [] }

# The loop below cannot know a later marker until it reaches it; recompute each
# file's marker ranges once so content ownership remains exact and deterministic.
corpus_files.each do |relative_path, text|
  lines = text.lines
  markers = []
  lines.each_index do |index|
    match = lines[index].match(/\A<!-- applied-learning: ([a-z0-9-]+) -->\n?\z/)
    markers << [index, match[1]] if match
  end

  markers.each_with_index do |(index, slug), marker_index|
    next_index = markers[marker_index + 1]&.first || lines.length
    expected_anchor = "<a id=\"applied-learning-#{slug}\"></a>\n"
    fail_validation("#{relative_path}:#{index + 1} has no matching anchor") unless lines[index + 1] == expected_anchor
    content = canonical_entry(lines[(index + 2)...next_index])
    found[slug] << {
      "destination" => relative_path,
      "anchor" => "applied-learning-#{slug}",
      "digest" => Digest::SHA256.hexdigest(content),
      "content" => content
    }
  end
end

inventory_by_slug = entries.to_h { |entry| [entry.fetch("slug"), entry] }
unknown = found.keys - inventory_by_slug.keys
fail_validation("un-inventoried corpus entries: #{unknown.join(", ")}") unless unknown.empty?

entries.each do |entry|
  slug = entry.fetch("slug")
  fail_validation("#{slug}: status must be live or retired") unless %w[live retired].include?(entry["status"])
  fail_validation("#{slug}: invalid class") unless %w[security-invariant correctness process tooling].include?(entry["class"])
  fail_validation("#{slug}: created must be a date") unless date?(entry["created"])
  fail_validation("#{slug}: scope must be an array of strings") unless
    entry["scope"].is_a?(Array) && entry["scope"].all? { |anchor| anchor.is_a?(String) }
  fail_validation("#{slug}: source_session must be a string") unless entry["source_session"].is_a?(String)
  fail_validation("#{slug}: last_confirmed must be null or a date") unless
    entry.key?("last_confirmed") && (entry["last_confirmed"].nil? || date?(entry["last_confirmed"]))
  fail_validation("#{slug}: confirmed_by must be null or a string") unless
    entry.key?("confirmed_by") && (entry["confirmed_by"].nil? || entry["confirmed_by"].is_a?(String))
  fail_validation("#{slug}: revisit_when must be null or a string") unless
    entry["revisit_when"].nil? || entry["revisit_when"].is_a?(String)
  if entry["status"] == "live"
    fail_validation("#{slug}: live destination is in archive") if
      entry["destination"] == archive_root || entry["destination"].start_with?(archive_root + "/")
  else
    fail_validation("#{slug}: retired destination must be its topic archive") unless
      entry["destination"] == "#{archive_root}/#{entry.fetch("topic")}.md"
    fail_validation("#{slug}: retired_on must be a date") unless date?(entry["retired_on"])
    reasons = %w[STALE CONTRADICTED SUPERSEDED DUPLICATE ONE-OFF NEGATIVE-CLAIM TOO-NARROW MERGED DECAYED]
    fail_validation("#{slug}: invalid retired_reason") unless reasons.include?(entry["retired_reason"])
    replacement = entry["superseded_by"]
    fail_validation("#{slug}: superseded_by must be null or a live slug") unless
      entry.key?("superseded_by") && (replacement.nil? ||
        (replacement.is_a?(String) && inventory_by_slug[replacement]&.fetch("status") == "live"))
    fail_validation("#{slug}: MERGED requires superseded_by") if entry["retired_reason"] == "MERGED" && replacement.nil?
    fail_validation("#{slug}: retired entry cannot be always_loaded") unless entry["always_loaded"] == false
  end
  owned = found.fetch(slug, [])
  fail_validation("#{slug} is missing from its destination") unless owned.length == 1

  location = "#{entry.fetch("destination")}##{entry.fetch("anchor")}"
  fail_validation("#{slug} destination/anchor mismatch at #{location}") unless
    owned.first.fetch("destination") == entry.fetch("destination") && owned.first.fetch("anchor") == entry.fetch("anchor")
  fail_validation("#{slug} content digest mismatch") unless owned.first.fetch("digest") == entry.fetch("content_sha256")
end

duplicate_owners = found.select { |_slug, owners| owners.length > 1 }.keys
fail_validation("multiply owned entries: #{duplicate_owners.join(", ")}") unless duplicate_owners.empty?

claude = corpus_files.fetch("CLAUDE.md")
applied_section = claude.split(/^## Applied Learning\n/, 2).fetch(1, "")
fail_validation("CLAUDE.md has no Applied Learning section") if applied_section.empty?
claude_applied_markers = applied_section.scan(/^<!-- applied-learning: ([a-z0-9-]+) -->$/).flatten
fail_validation("CLAUDE.md Applied Learning working set is not exactly 12 entries") unless claude_applied_markers.length == 12
fail_validation("CLAUDE.md Applied Learning contains an unmarked entry") unless
  applied_section.lines.count { |line| line.start_with?("**") } == claude_applied_markers.length
fail_validation("CLAUDE.md contains a non-working-set Applied Learning entry") unless
  claude_applied_markers.sort == entries.select { |entry| entry.fetch("always_loaded") }.map { |entry| entry.fetch("slug") }.sort

activation_paths = {
  "acp-mcp" => ".claude/skills/applied-learning-acp-mcp.md",
  "shell-containment" => ".claude/skills/applied-learning-shell-containment.md",
  "testing-live-runtime" => ".claude/skills/applied-learning-testing-live-runtime.md",
  "otp-ownership-cleanup" => ".claude/skills/applied-learning-otp-ownership-cleanup.md",
  "persistence-database" => ".claude/skills/applied-learning-persistence-database.md",
  "providers-oauth" => ".claude/skills/applied-learning-providers-oauth.md",
  "council-review" => ".claude/skills/applied-learning-council-review.md",
  "filesystem-git" => ".claude/skills/applied-learning-filesystem-git.md",
  "ui" => ".claude/skills/socket-component.md"
}
activation_paths.each do |topic, path|
  fail_validation("CLAUDE.md activation index omits #{topic}") unless claude.include?(path)
  read_required(File.join(ROOT, path))
end

claude_words = claude.split.length
working_set = entries.select { |entry| entry.fetch("always_loaded") }.map { |entry| found.fetch(entry.fetch("slug")).first.fetch("content") }.join
working_set_words = working_set.split.length
fail_validation("CLAUDE.md exceeds the 4,000-word migration ceiling: #{claude_words}") if claude_words > 4_000
fail_validation("Applied Learning working set exceeds 950 words: #{working_set_words}") if working_set_words > 950

live_entries = entries.select { |entry| entry["status"] == "live" }
word_sets = live_entries.to_h { |entry| [entry["slug"], title_words(entry.fetch("title"))] }
live_entries.each do |entry|
  slug = entry.fetch("slug")
  content = found.fetch(slug).first.fetch("content")
  words = content.split.length
  warn_validation("#{slug} exceeds 400 words: #{words}", inventory["caps_enforced"] == true) if words > 400
  next if entry.fetch("created") < inventory.fetch("admission_cutover")

  fail_validation("#{slug}: new entry exceeds 400 words: #{words}") if words > 400
  paragraphs = content.split(/\n[ \t]*\n/)
  incident_start = /\A(?:\d{4}-\d{2}-\d{2}|On 20\d\d-|\(20\d\d|Reinforced|Recurred|Also found|Reconfirmed|Re-confirmed|Updated?)/i
  fail_validation("#{slug}: one rule per marker; later incident paragraph") if paragraphs.drop(1).any? { |paragraph| paragraph.lstrip.match?(incident_start) }
  duplicate = live_entries.find do |other|
    other["slug"] != slug && jaccard(word_sets.fetch(slug), word_sets.fetch(other["slug"])) >= 0.6
  end
  fail_validation("#{slug}: near-duplicate of #{duplicate["slug"]}: cite or extend it instead") if duplicate
  gap = /\b(currently|not yet|until\b[^.]*\bimplemented|does not (yet )?(exist|expose))\b/i
  fail_validation("#{slug}: gap wording requires revisit_when") if content.match?(gap) &&
    (!entry["revisit_when"].is_a?(String) || entry["revisit_when"].strip.empty?)
end
live_entries.group_by { |entry| entry["destination"] }.sort.each do |destination, topic_entries|
  next unless destination.match?(%r{\A\.claude/skills/applied-learning-[^/]+\.md\z})
  words = topic_entries.sum { |entry| found.fetch(entry["slug"]).first.fetch("content").split.length }
  warn_validation("#{destination} live entries exceed 8,000 words: #{words}", inventory["caps_enforced"] == true) if words > 8_000
end
usage_path = File.join(ROOT, ".claude/skills/applied-learning-usage.json")
begin
  generated_on = JSON.parse(File.read(usage_path, encoding: "UTF-8"))["generated_on"]
rescue Errno::ENOENT, JSON::ParserError
  generated_on = nil
end
warn_validation("monthly review overdue: run ruby .claude/applied_learning_review.rb --report") unless
  date?(generated_on) && Date.iso8601(generated_on) >= Date.today - 35

puts "Applied Learning validation: PASS"
puts "entries=#{entries.length} live=#{live_entries.length} retired=#{entries.length - live_entries.length} destinations=#{destination_paths.length} owned_once=#{found.values.count { |owners| owners.length == 1 }}"
puts "claude_words=#{claude_words} claude_bytes=#{claude.bytesize} working_set_entries=12 working_set_words=#{working_set_words} working_set_bytes=#{working_set.bytesize}"
topic_counts = entries.group_by { |entry| entry.fetch("topic") }.transform_values(&:length)
puts "topics=#{topic_counts.sort.to_h}"

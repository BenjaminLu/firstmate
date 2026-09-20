#!/usr/bin/env bash
# Contract tests for .github/workflows/ci.yml's runner-spend safeguards.
#
# Origin: the 2026-09-12 GitHub Actions starvation incident. firstmate CI had no
# concurrency deduplication, so every superseded PR head kept its full job
# fan-out, and four jobs carried no timeout at all. These tests hold both
# safeguards: PR runs supersede within one PR while main pushes are never
# cancelled, and every CI job carries a finite hang tripwire.
#
# The workflow is parsed as YAML and its concurrency expressions are resolved
# against simulated pull_request and push contexts, so the assertions describe
# what GitHub would do, not how the file happens to be spelled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"

assert_present "$CI_WORKFLOW" ".github/workflows/ci.yml is missing"
command -v ruby >/dev/null 2>&1 \
  || fail "ruby is required to parse .github/workflows/ci.yml as YAML"

# Resolve the workflow's concurrency contract under one simulated event and
# print "<group><TAB><cancel-in-progress>". Only the two expression constructs
# this workflow uses are resolved: an `a || b` fallback and an `==` comparison.
resolve_concurrency() {
  local event=$1 pr_number=$2 run_id=$3
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
concurrency = doc.fetch("concurrency")
context = {
  "github.workflow" => doc.fetch("name"),
  "github.event_name" => ARGV[1],
  "github.event.pull_request.number" => ARGV[2],
  "github.run_id" => ARGV[3],
}

value = lambda do |token|
  token = token.strip
  next token[1..-2] if token.start_with?("\x27") && token.end_with?("\x27")
  raise "unresolvable context reference: #{token}" unless context.key?(token)
  context.fetch(token)
end

evaluate = lambda do |expression|
  expression = expression.strip
  if expression.include?("==")
    left, right = expression.split("==", 2)
    next value.call(left) == value.call(right) ? "true" : "false"
  end
  resolved = expression.split("||").map { |token| value.call(token) }.find { |v| !v.empty? }
  resolved.to_s
end

interpolate = lambda do |raw|
  raw.to_s.gsub(/\$\{\{(.+?)\}\}/) { evaluate.call(Regexp.last_match(1)) }
end

puts [interpolate.call(concurrency.fetch("group")),
      interpolate.call(concurrency.fetch("cancel-in-progress"))].join("\t")
' "$CI_WORKFLOW" "$event" "$pr_number" "$run_id"
}

job_timeout() {
  ruby -ryaml -e '
puts YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" "$1"
}

group_of() { printf '%s\n' "$1" | cut -f1; }
cancel_of() { printf '%s\n' "$1" | cut -f2; }

test_pr_pushes_supersede_within_one_pr() {
  local first second
  first=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  second=$(resolve_concurrency pull_request 108 900002) || fail "could not resolve PR concurrency"
  [ "$(group_of "$first")" = "$(group_of "$second")" ] \
    || fail "two runs of one PR must share a concurrency group, got $(group_of "$first") and $(group_of "$second")"
  [ "$(cancel_of "$first")" = true ] \
    || fail "PR runs must cancel the in-progress run, got $(cancel_of "$first")"
  pass "a newer push to one PR supersedes that PR's in-flight CI"
}

test_separate_prs_do_not_cancel_each_other() {
  local one two
  one=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  two=$(resolve_concurrency pull_request 109 900003) || fail "could not resolve PR concurrency"
  [ "$(group_of "$one")" != "$(group_of "$two")" ] \
    || fail "distinct PRs must not share a concurrency group ($(group_of "$one"))"
  pass "distinct PRs get distinct concurrency groups"
}

test_main_pushes_are_never_cancelled() {
  local first second
  first=$(resolve_concurrency push '' 900010) || fail "could not resolve push concurrency"
  second=$(resolve_concurrency push '' 900011) || fail "could not resolve push concurrency"
  [ "$(group_of "$first")" != "$(group_of "$second")" ] \
    || fail "each main push must get its own concurrency group, got $(group_of "$first") twice"
  [ "$(cancel_of "$first")" = false ] \
    || fail "push runs must never cancel an in-progress run, got $(cancel_of "$first")"
  pass "every main push keeps its own group and is never cancelled"
}

test_every_job_has_a_finite_timeout() {
  local reported
  reported=$(ruby -ryaml -e '
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  timeout = job["timeout-minutes"]
  next if timeout.is_a?(Integer) && timeout > 0
  puts "#{name}: #{timeout.inspect}"
end
' "$CI_WORKFLOW") || fail "could not read job timeouts from ci.yml"
  [ -z "$reported" ] || fail "these CI jobs have no finite hang tripwire:"$'\n'"$reported"
  pass "every ci.yml job carries a finite timeout"
}

# The four jobs the incident found unbounded, at the report's recommended caps.
test_previously_unbounded_jobs_keep_their_caps() {
  local job expected actual
  while read -r job expected; do
    [ -n "$job" ] || continue
    actual=$(job_timeout "$job") || fail "could not read the $job timeout"
    [ "$actual" = "$expected" ] \
      || fail "$job timeout must stay $expected minutes, got $actual"
  done <<'CAPS'
lint 25
test-coverage 5
tests-timing-aggregate 5
invariants 5
CAPS
  pass "the incident's unbounded jobs keep their recommended caps"
}

# Cancellation makes an undersized cap costlier: a falsely tripped job now also
# discards a run nobody replaced. These bounds were measured, not guessed.
test_measured_lanes_keep_their_existing_bounds() {
  local job expected actual
  while read -r job expected; do
    [ -n "$job" ] || continue
    actual=$(job_timeout "$job") || fail "could not read the $job timeout"
    [ "$actual" = "$expected" ] \
      || fail "$job timeout must stay $expected minutes, got $actual"
  done <<'CAPS'
tests-portable-parallel-1 10
tests-portable-parallel-2 10
tests-portable-serial 30
tests-herdr 75
macos-stock-bash 10
CAPS
  pass "the already-measured lane bounds are unchanged"
}

# The two portable parallel lanes carry the same isolation proof, so nothing in
# the runner or the coverage guard distinguishes them - both would accept
# --jobs. What separates them is measured shape: lane 1 is packing-bound and
# gains, lane 2 holds one script that is the whole lane and gains nothing while
# costing more runner-seconds. This branch is the demonstration that the
# distinction is easy to lose: both lanes were given the flag together on one
# argument, and only the measurement said one was wrong.
#
# Those worker counts are also an input to a model now. bin/fm-test-run.sh packs
# the lanes by each one's projected WALL, and a lane's wall is its makespan over
# the workers CI actually gives it - so if this file and that script disagree
# about the counts, the model is projecting a lane that does not exist and the
# packing it approves means nothing. Assert against the runner's own reported
# numbers rather than literals, so the two can only be changed together.
test_parallel_lane_concurrency_matches_the_measured_shape() {
  local coverage
  coverage=$("$ROOT/bin/fm-test-run.sh" --check-coverage) \
    || fail "could not read the runner's coverage report"
  ruby -ryaml - "$CI_WORKFLOW" "$coverage" <<'RUBY' || fail "parallel lane concurrency contract"
jobs = YAML.load_file(ARGV[0]).fetch("jobs")
coverage = ARGV[1]

def reported(coverage, key)
  match = coverage[/#{key}=(\d+)/, 1]
  raise "bin/fm-test-run.sh --check-coverage did not report #{key}" if match.nil?
  match.to_i
end

# Comments in these steps quote the measured --jobs 2 numbers, so match the
# executable lines only; matching the prose would assert on the explanation
# rather than on what the runner is actually told to do.
def run_step(job)
  steps = job.fetch("steps").select { |s| s.is_a?(Hash) && s["name"].to_s.start_with?("Run portable parallel shard") }
  raise "expected exactly one suite-run step, found #{steps.length}" unless steps.length == 1
  steps.first.fetch("run").lines.reject { |l| l.strip.start_with?("#") }.join
end

# What the workflow actually asks for: an explicit "--jobs N", or one worker.
def workflow_jobs(step)
  step[/--jobs[=\s]+(\d+)/, 1]&.to_i || 1
end

lanes = {
  1 => jobs.fetch("tests-portable-parallel-1"),
  2 => jobs.fetch("tests-portable-parallel-2"),
}

lanes.each do |n, job|
  asked = workflow_jobs(run_step(job))
  modeled = reported(coverage, "parallel_lane#{n}_jobs")
  raise "shard #{n} runs with #{asked} worker(s) here but bin/fm-test-run.sh models #{modeled}; the wall projection that packs these lanes is describing a lane that does not exist" \
    unless asked == modeled
end

raise "lane 1 must keep more than one worker: it is packing-bound and its wall is a makespan, not a sum" \
  unless workflow_jobs(run_step(lanes.fetch(1))) > 1

raise "lane 2 must stay serial: it is one script that is the whole lane, so a second worker has nothing to run. See docs/fm-test-portable-shards.md before changing this." \
  unless workflow_jobs(run_step(lanes.fetch(2))) == 1

# The cap the model is held against is this file's, and the model only mirrors
# it. Mirrors drift; this is what stops one drifting unnoticed.
modeled_cap = reported(coverage, "parallel_wall_cap_ms")
lanes.each do |n, job|
  cap = job.fetch("timeout-minutes") * 60_000
  raise "shard #{n} caps at #{cap}ms but bin/fm-test-run.sh models its lanes against #{modeled_cap}ms" \
    unless cap == modeled_cap
end

budget = reported(coverage, "parallel_wall_budget_ms")
raise "the modeled packing budget #{budget}ms must stay below the #{modeled_cap}ms job cap it protects" \
  unless budget < modeled_cap
RUBY
  pass "portable parallel lane worker counts and job cap match the model that packs them"
}

test_ci_matrices_match_executable_partitions() {
  ruby -ryaml -ropen3 - "$CI_WORKFLOW" "$ROOT" <<'RUBY' || fail "CI partition contract"
jobs = YAML.load_file(ARGV[0]).fetch("jobs")
root = ARGV[1]
serial = jobs.fetch("tests-portable-serial").fetch("strategy")
raise "serial failures must not cancel other shards" unless serial.fetch("fail-fast") == false
matrix = serial.fetch("matrix")
raise "unexpected serial dimensions" unless matrix.keys == ["shard"]
shards = matrix.fetch("shard")
lanes, status = Open3.capture2(File.join(root, "bin/fm-test-run.sh"), "--list-lanes")
raise "cannot list runner lanes" unless status.success?
actual = lanes.lines.map(&:strip).select { |l| l.match?(/\Aportable-serial-\d+of\d+\z/) }
expected = shards.map { |s| "portable-serial-#{s}of#{shards.length}" }
raise "CI matrix and runner disagree" unless actual.sort == expected.sort
herdr = jobs.fetch("tests-herdr").fetch("strategy")
raise "Herdr failures must not cancel another shard" unless herdr.fetch("fail-fast") == false
matrix = herdr.fetch("matrix")
raise "unexpected Herdr dimensions" unless matrix.keys == ["shard"]
shards = matrix.fetch("shard")
actual = lanes.lines.map(&:strip).select { |l| l.match?(/\Areal-herdr-gated-\d+of\d+\z/) }
expected = shards.map { |s| "real-herdr-gated-#{s}of#{shards.length}" }
raise "CI Herdr matrix and runner disagree" unless actual.sort == expected.sort
lint = jobs.fetch("lint").fetch("strategy")
raise "lint failures must not cancel another partition" unless lint.fetch("fail-fast") == false
matrix = lint.fetch("matrix")
raise "unexpected lint dimensions" unless matrix.keys == ["partition"]
parts = matrix.fetch("partition")
roots = parts.flat_map do |p|
  output, result = Open3.capture2(File.join(root, "bin/fm-lint.sh"), "--partition", "#{p}of#{parts.length}", "--list-files")
  raise "unsupported lint partition" unless result.success?
  output.lines.map(&:strip)
end
canonical, result = Open3.capture2({"CI" => "true"}, File.join(root, "bin/fm-lint.sh"), "--list-files")
raise "lint matrix loses or duplicates canonical roots" unless result.success? && roots.sort == canonical.lines.map(&:strip).sort
RUBY
  pass "CI matrices cover every executable serial and Herdr lane and canonical lint root exactly once"
}

test_ci_matrices_match_executable_partitions
test_parallel_lane_concurrency_matches_the_measured_shape
test_pr_pushes_supersede_within_one_pr
test_separate_prs_do_not_cancel_each_other
test_main_pushes_are_never_cancelled
test_every_job_has_a_finite_timeout
test_previously_unbounded_jobs_keep_their_caps
test_measured_lanes_keep_their_existing_bounds

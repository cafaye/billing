require "json"
require "coverage"
require "fileutils"

# Measures line and branch coverage of the money paths, in a process that
# measures nothing else.
#
# `Coverage` records only what executes *after* `Coverage.start`, and a Rails
# process autoloads its application files on first reference — so measuring from
# inside the suite would report a money file as covered when the corpus had
# merely touched a constant that happened to pull it in. Worse, re-`load`ing an
# already-autoloaded file does not re-point the methods: the calls keep hitting
# the first definition, and the fresh ISeq records nothing. Both failure modes
# make a gate that passes for the wrong reason.
#
# So the probe starts coverage *first*, then boots the application with eager
# loading on, then runs the corpus. Every application file is therefore read
# inside the measurement window, the counts are the real ones, and the report is
# restricted to the files under test.
#
# The standard library does the measuring and no gem is involved, which is the
# point (PLAN §3).
module MoneyCoverage
  # The corpora `measure` can be pointed at. Named rather than passed as a lambda,
  # because a lambda defined in the minitest process cannot be run in the probe
  # process — which is exactly the point of the probe.
  CORPORA = {
    full: "MoneyCoverageExercise.full",
    minimal: "MoneyCoverageExercise.minimal"
  }.freeze

  class << self
    def measure(paths, corpus: :full)
      raise ArgumentError, "unknown corpus #{corpus.inspect}" unless CORPORA.key?(corpus)

      tmp = Rails.root.join("tmp")
      FileUtils.mkdir_p(tmp)
      script = tmp.join("money_coverage_probe.rb")
      report = tmp.join("money_coverage_report.json")
      FileUtils.rm_f(report)

      File.write(script, probe_source(paths, corpus, report))
      pid = Process.spawn(clean_env, RbConfig.ruby, script.to_s, out: File::NULL, err: $stderr)
      Process.wait(pid)
      status = $?

      raise "the coverage probe exited with #{status.exitstatus} and wrote no report" unless status.success?
      raise "the coverage probe wrote no report" unless File.exist?(report)

      JSON.parse(File.read(report))
    ensure
      FileUtils.rm_f(script)
    end

    private
      # Only what the probe needs to boot. The suite's own variables are dropped
      # so a value the tests happen to have set cannot change what is measured.
      def clean_env
        {
          "RAILS_ENV" => "test",
          "BUNDLE_GEMFILE" => Rails.root.join("Gemfile").to_s,
          "BUNDLE_FROZEN" => "true",
          # The suite may be running under a coverage tool of its own; nothing
          # here should inherit it.
          "COVERAGE" => "false"
        }
      end

      # A standalone program rather than `eval`, so a failure inside it is a
      # readable Ruby backtrace with real line numbers.
      def probe_source(paths, corpus, report)
        <<~RUBY
          require "coverage"

          # Before anything else, including the framework: every line the gate is
          # about has to execute inside this window.
          Coverage.start(lines: true, branches: true)

          require #{Rails.root.join("config/environment").to_s.inspect}

          # Eager loading is what makes the counts mean anything: autoloading
          # would leave a file that the corpus happens not to touch entirely
          # unmeasured, which would read as "no uncovered lines" rather than as
          # "not measured".
          Rails.application.eager_load!

          require #{Rails.root.join("test/support/money_coverage.rb").to_s.inspect}
          require #{Rails.root.join("test/support/money_coverage_exercise.rb").to_s.inspect}

          #{CORPORA.fetch(corpus)}

          File.write(
            #{report.to_s.inspect},
            JSON.generate(MoneyCoverage::Report.new(#{paths.map { |path| Rails.root.join(path).to_s }.inspect}).to_h)
          )
        RUBY
      end
  end

  # Walks a `Coverage.result` and reports what was *not* executed, restricted to
  # the files under test. Runs inside the probe process.
  class Report
    def initialize(paths)
      @paths = paths
    end

    def to_h
      result = Coverage.result

      {
        "files" => @paths.map { |path| relative(path) },
        "executable_lines" => executable_lines(result),
        "uncovered_lines" => uncovered_lines(result),
        "uncovered_branches" => uncovered_branches(result)
      }
    end

    private
      def relative(path)
        path.delete_prefix("#{Dir.pwd}/")
      end

      def entry_for(result, path)
        result[path] || result[File.realpath(path)] || {}
      end

      # `Coverage` reports a line three ways: a count, `nil` for a line that
      # cannot execute at all (a comment, a blank, an `end`), and `0` for a line
      # that was reachable and never ran. Only the `0` is an uncovered line.
      def executable_lines(result)
        @paths.sum { |path| entry_for(result, path).fetch(:lines, []).count { |count| !count.nil? } }
      end

      def uncovered_lines(result)
        @paths.flat_map do |path|
          entry_for(result, path).fetch(:lines, []).each_index.filter_map do |index|
            [ relative(path), index + 1 ] if entry_for(result, path).fetch(:lines, [])[index] == 0
          end
        end
      end

      # A branch is a conditional arm. `Coverage` keys them by the line the branch
      # sits on, and an arm whose count is nil was never taken.
      def uncovered_branches(result)
        @paths.flat_map do |path|
          entry_for(result, path).fetch(:branches, {}).flat_map do |line, arms|
            arms.each_with_index.filter_map do |arm, index|
              [ relative(path), line, index ] if arm.nil?
            end
          end
        end
      end
  end
end

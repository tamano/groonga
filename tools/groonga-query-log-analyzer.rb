#!/usr/bin/env ruby

require 'English'
require 'optparse'
require 'cgi'
require 'thread'

class GroongaQueryLogAnaylzer
  def initialize
    setup_options
  end

  def run(argv=nil)
    log_paths = @option_parser.parse!(argv || ARGV)

    parser = QueryLogParser.new
    threads = []
    log_paths.each do |log_path|
      threads << Thread.new do
        File.open(log_path) do |log|
          parser.parse(log)
        end
      end
    end
    threads.each do |thread|
      thread.join
    end

    reporter = ConsoleQueryLogReporter.new(parser.statistics)
    reporter.apply_options(@options)
    reporter.report
  end

  private
  def setup_options
    @options = {}
    @options[:n_entries] = 10
    @options[:order] = "-elapsed"
    @options[:color] = :auto
    @options[:output] = "-"
    @options[:slow_threshold] = 0.05

    @option_parser = OptionParser.new do |parser|
      parser.banner += " LOG1 ..."

      parser.on("-n", "--n-entries=N",
                Integer,
                "Show top N entries",
                "(#{@options[:n_entries]})") do |n|
        @options[:n_entries] = n
      end

      available_orders = ["elapsed", "-elapsed", "start-time", "-start-time"]
      parser.on("--order=ORDER",
                available_orders,
                "Sort by ORDER",
                "available values: [#{available_orders.join(', ')}]",
                "(#{@options[:order]})") do |order|
        @options[:order] = order
      end

      color_options = [
        [:auto, :auto],
        ["-", false],
        ["no", false],
        ["false", false],
        ["+", true],
        ["yes", true],
        ["true", true],
      ]
      parser.on("--[no-]color=[auto]",
                color_options,
                "Enable color output",
                "(#{@options[:color]})") do |color|
        if color.nil?
          @options[:color] = true
        else
          @options[:color] = color
        end
      end

      parser.on("--output=PATH",
                "Output to PATH.",
                "'-' PATH means standard output.",
                "(#{@options[:output]})") do |output|
        @options[:output] = output
      end

      parser.on("--slow-threshold=THRESHOLD",
                Float,
                "Use THRESHOLD seconds to detect slow operations.",
                "(#{@options[:slow_threshold]})") do |threshold|
        @options[:slow_threshold] = threshold
      end
    end
  end

  class Command
    class << self
      @@registered_commands = {}
      def register(name, klass)
        @@registered_commands[name] = klass
      end

      def parse(command_path)
        name, parameters_string = command_path.split(/\?/, 2)
        parameters = {}
        parameters_string.split(/&/).each do |parameter_string|
          key, value = parameter_string.split(/\=/, 2)
          parameters[key] = CGI.unescape(value)
        end
        name = name.gsub(/\A\/d\//, '')
        name, output_type = name.split(/\./, 2)
        parameters["output_type"] = output_type if output_type
        command_class = @@registered_commands[name] || self
        command_class.new(name, parameters)
      end
    end

    attr_reader :name, :parameters
    def initialize(name, parameters)
      @name = name
      @parameters = parameters
    end

    def ==(other)
      other.is_a?(self.class) and
        @name == other.name and
        @parameters == other.parameters
    end
  end

  class SelectCommand < Command
    register("select", self)

    def sortby
      @parameters["sortby"]
    end

    def scorer
      @parameters["scorer"]
    end

    def conditions
      @parameters["filter"].split(/(?:&&|&!|\|\|)/).collect do |condition|
        condition = condition.strip
        condition = condition.gsub(/\A[\s\(]*/, '')
        condition = condition.gsub(/[\s\)]*\z/, '') unless /\(/ =~ condition
        condition
      end
    end

    def output_columns
      @parameters["output_columns"]
    end
  end

  class Statistic
    attr_reader :context_id, :start_time, :raw_command
    attr_reader :trace, :elapsed, :return_code
    def initialize(context_id)
      @context_id = context_id
      @start_time = nil
      @command = nil
      @raw_command = nil
      @trace = []
      @elapsed = nil
      @return_code = 0
    end

    def start(start_time, command)
      @start_time = start_time
      @raw_command = command
    end

    def finish(elapsed, return_code)
      @elapsed = elapsed
      @return_code = return_code
    end

    def command
      @command ||= Command.parse(@raw_command)
    end

    def elapsed_in_seconds
      nano_seconds_to_seconds(@elapsed)
    end

    def end_time
      @start_time + elapsed_in_seconds
    end

    def each_trace_info
      previous_elapsed = 0
      ensure_parse_command
      @trace.each_with_index do |(trace_elapsed, trace_label), i|
        relative_elapsed = trace_elapsed - previous_elapsed
        previous_elapsed = trace_elapsed
        trace_info = {
          :i => i,
          :elapsed => trace_elapsed,
          :elapsed_in_seconds => nano_seconds_to_seconds(trace_elapsed),
          :relative_elapsed => relative_elapsed,
          :relative_elapsed_in_seconds => nano_seconds_to_seconds(relative_elapsed),
          :label => trace_label,
          :context => trace_context(trace_label, i),
        }
        yield trace_info
      end
    end

    def select_command?
      command.name == "select"
    end

    private
    def nano_seconds_to_seconds(nano_seconds)
      nano_seconds / 1000.0 / 1000.0 / 1000.0
    end

    def trace_context(label, i)
      case label
      when /\Afilter\(/
        @select_command.conditions[i]
      when /\Asort\(/
        @select_command.sortby
      when /\Ascore\(/
        @select_command.scorer
      when /\Aoutput\(/
        @select_command.output_columns
      else
        label
      end
    end

    def ensure_parse_command
      return unless select_command?
      @select_command = SelectCommand.parse(@raw_command)
    end
  end

  class SizedStatistics < Array
    def initialize(size)
      @size = size
    end
  end

  class QueryLogParser
    attr_reader :statistics
    def initialize
      @mutex = Mutex.new
      @statistics = []
    end

    def parse(input)
      statistics = []
      current_statistics = {}
      input.each_line do |line|
        case line
        when /\A(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d+)\|(.+?)\|([>:<])/
          year, month, day, hour, minutes, seconds, micro_seconds =
            $1, $2, $3, $4, $5, $6, $7
          context_id = $8
          type = $9
          rest = $POSTMATCH.strip
          time_stamp = Time.local(year, month, day, hour, minutes, seconds,
                                  micro_seconds)
          parse_line(statistics, current_statistics,
                time_stamp, context_id, type, rest)
        end
      end
      @mutex.synchronize do
        @statistics.concat(statistics)
      end
    end

    private
    def parse_line(statistics, current_statistics,
                   time_stamp, context_id, type, rest)
      case type
      when ">"
        statistic = Statistic.new(context_id)
        statistic.start(time_stamp, rest)
        current_statistics[context_id] = statistic
      when ":"
        return unless /\A(\d+) / =~ rest
        elapsed = $1
        label = $POSTMATCH.strip
        statistic = current_statistics[context_id]
        return if statistic.nil?
        statistic.trace << [elapsed.to_i, label]
      when "<"
        return unless /\A(\d+) rc=(\d+)/ =~ rest
        elapsed = $1
        return_code = $2
        statistic = current_statistics.delete(context_id)
        return if statistic.nil?
        statistic.finish(elapsed.to_i, return_code.to_i)
        statistics << statistic
      end
    end
  end

  class QueryLogReporter
    include Enumerable

    attr_accessor :n_entries, :slow_threshold
    def initialize(statistics)
      @statistics = statistics
      @order = "-elapsed"
      @n_entries = 10
      @slow_threshold = 0.05
      @sorted_statistics = nil
    end

    def apply_options(options)
      self.order = options[:order] || @order
      self.n_entries = options[:n_entries] || @n_entries
      self.slow_threshold = options[:slow_threshold] || @slow_threshold
    end

    def order=(order)
      return if @order == order
      @order = order
      @sorted_statistics = nil
    end

    def sorted_statistics
      @sorted_statistics ||= @statistics.sort_by(&sorter)
    end

    def each
      sorted_statistics.each_with_index do |statistic, i|
        break if i >= @n_entries
        yield statistic
      end
    end

    private
    def sorter
      case @order
      when "elapsed"
        lambda do |statistic|
          -statistic.elapsed
        end
      when "-elapsed"
        lambda do |statistic|
          -statistic.elapsed
        end
      when "-start-time"
        lambda do |statistic|
          -statistic.start_time
        end
      else
        lambda do |statistic|
          statistic.start_time
        end
      end
    end

    def slow?(elapsed)
      elapsed >= @slow_threshold
    end
  end

  class ConsoleQueryLogReporter < QueryLogReporter
    class Color
      NAMES = ["black", "red", "green", "yellow",
               "blue", "magenta", "cyan", "white"]

      attr_reader :name
      def initialize(name, options={})
        @name = name
        @foreground = options[:foreground]
        @foreground = true if @foreground.nil?
        @intensity = options[:intensity]
        @bold = options[:bold]
        @italic = options[:italic]
        @underline = options[:underline]
      end

      def foreground?
        @foreground
      end

      def intensity?
        @intensity
      end

      def bold?
        @bold
      end

      def italic?
        @italic
      end

      def underline?
        @underline
      end

      def ==(other)
        self.class === other and
          [name, foreground?, intensity?,
           bold?, italic?, underline?] ==
          [other.name, other.foreground?, other.intensity?,
           other.bold?, other.italic?, other.underline?]
      end

      def sequence
        sequence = []
        if @name == "none"
        elsif @name == "reset"
          sequence << "0"
        else
          foreground_parameter = foreground? ? 3 : 4
          foreground_parameter += 6 if intensity?
          sequence << "#{foreground_parameter}#{NAMES.index(@name)}"
        end
        sequence << "1" if bold?
        sequence << "3" if italic?
        sequence << "4" if underline?
        sequence
      end

      def escape_sequence
        "\e[#{sequence.join(';')}m"
      end

      def +(other)
        MixColor.new([self, other])
      end
    end

    class MixColor
      attr_reader :colors
      def initialize(colors)
        @colors = colors
      end

      def sequence
        @colors.inject([]) do |result, color|
          result + color.sequence
        end
      end

      def escape_sequence
        "\e[#{sequence.join(';')}m"
      end

      def +(other)
        self.class.new([self, other])
      end

      def ==(other)
        self.class === other and colors == other.colors
      end
    end

    def initialize(statistics)
      super
      @color = :auto
      @output = $stdout
      @reset_color = Color.new("reset")
      @color_schema = {
        :elapsed => {:foreground => :white, :background => :green},
        :time => {:foreground => :white, :background => :cyan},
        :slow => {:foreground => :white, :background => :red},
      }
    end

    def apply_options(options)
      super
      @color = options[:color] || @color
      @output = options[:output] || @output
      @output = $stdout if @output == "-"
    end

    def report
      setup_output do |output|
        setup_color(output) do
          digit = Math.log10(n_entries).truncate + 1
          each_with_index do |statistic, i|
            output.puts "%*d) %s" % [digit, i + 1, format_heading(statistic)]
            command = statistic.command
            output.puts "  name: <#{command.name}>"
            output.puts "  parameters:"
            command.parameters.each do |key, value|
              output.puts "    <#{key}>: <#{value}>"
            end
            statistic.each_trace_info do |info|
              relative_elapsed_in_seconds = info[:relative_elapsed_in_seconds]
              formatted_elapsed = "%8.8f" % relative_elapsed_in_seconds
              if slow?(relative_elapsed_in_seconds)
                formatted_elapsed = colorize(formatted_elapsed, :slow)
              end
              trace_report = " %2d) %s: %s" % [info[:i] + 1,
                                               formatted_elapsed,
                                               info[:label]]
              context = info[:context]
              if context
                if slow?(relative_elapsed_in_seconds)
                  context = colorize(context, :slow)
                end
                trace_report << " " << context
              end
              output.puts trace_report
            end
            output.puts
          end
        end
      end
    end

    private
    def guess_color_availability(output)
      return false unless output.tty?
      case ENV["TERM"]
      when /term(?:-color)?\z/, "screen"
        true
      else
        return true if ENV["EMACS"] == "t"
        false
      end
    end

    def setup_output
      if @output.is_a?(String)
        File.open(@output, "w") do |output|
          yield(output)
        end
      else
        yield(@output)
      end
    end

    def setup_color(output)
      color = @color
      @color = guess_color_availability(output) if @color == :auto
      yield
    ensure
      @color = color
    end

    def format_heading(statistic)
      formatted_elapsed = colorize("%8.8f" % statistic.elapsed_in_seconds,
                                   :elapsed)
      "[%s-%s (%s)](%d): %s" % [format_time(statistic.start_time),
                                format_time(statistic.end_time),
                                formatted_elapsed,
                                statistic.return_code,
                                statistic.raw_command]
    end

    def format_time(time)
      colorize(time.strftime("%Y-%m-%d %H:%M:%S.%u"), :time)
    end

    def colorize(text, schema_name)
      return text unless @color
      options = @color_schema[schema_name]
      color = Color.new("none")
      if options[:foreground]
        color += Color.new(options[:foreground].to_s, :bold => true)
      end
      if options[:background]
        color += Color.new(options[:background].to_s, :foreground => false)
      end
      "%s%s%s" % [color.escape_sequence, text, @reset_color.escape_sequence]
    end
  end
end

if __FILE__ == $0
  analyzer = GroongaQueryLogAnaylzer.new
  analyzer.run
end

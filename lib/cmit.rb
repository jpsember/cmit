#!/usr/bin/env ruby

require 'js_base'
require 'trollop'
require 'js_base/text_editor'

class ProgramException < Exception; end

class String
  def strip_heredoc
    gsub(/^#{scan(/^\s*/).min_by{|l|l.length}}/, "")
  end
end

class App

  COMMIT_CACHE_DIR = ".commit_cache"
  #
  # The git state representing the last successfully tested project is written here
  #
  GIT_STATE_TESTED_FILENAME = "#{COMMIT_CACHE_DIR}/state.txt"

  # The commit message to be used for the next commit, it is edited by the user,
  # stored in this file, and deleted when commit succeeds
  #
  COMMIT_MESSAGE_FILENAME = "#{COMMIT_CACHE_DIR}/editor_message.txt"

  # The commit message, after all comments are stripped; this is what is actually committed
  #
  COMMIT_MESSAGE_STRIPPED_FILENAME = "#{COMMIT_CACHE_DIR}/editor_message_stripped.txt"

  PREVIOUS_COMMIT_MESSAGE_FILENAME = "#{COMMIT_CACHE_DIR}/previous_editor_message.txt"

  COMMIT_MESSAGE_TEMPLATE_1=<<-EOS.strip_heredoc
  Issue #

  # Enter a commit message above, including at least one issue number prefixed with '#'.
  # You can have GitHub close the issue automatically by referring to the issue with
  # one of these (case-insensitive) forms:
  #
  #  'fixes #123', 'resolves #123', 'closes #123'.
  #
  EOS

  COMMIT_MESSAGE_TEMPLATE_2=<<-EOS.strip_heredoc

  # --------------------------------------------------------------------------
  # Previous commit's message:
  # --------------------------------------------------------------------------
  EOS


  COMMIT_MESSAGE_TEMPLATE_3=<<-EOS.strip_heredoc

  # --------------------------------------------------------------------------
  # Git repository status:
  # --------------------------------------------------------------------------
  EOS

  def run(argv)

    @options = parse_arguments(argv)
    @detail = @options[:detail]
    @verbose = @options[:verbose] || @detail
    @current_git_state = nil
    @last_tested_git_state = nil

    begin
      prepare_cache_dir(@options[:clean])

      if @options[:testonly] || !commit_is_necessary
        run_unit_tests
      elsif @options[:omit_tests]
        perform_commit_if_nec
      else
        puts "Starting unit tests in separate thread..." if @verbose
        thread = Thread.new do
          run_unit_tests
        end
        message = nil
        if commit_is_necessary
          message = edit_commit_message
        end
        puts "Waiting for unit tests to complete..." if @verbose
        thread.join
        perform_commit_with_message(message) if commit_is_necessary
      end

    rescue ProgramException => e
      puts "*** Aborted!  #{e.message}"
      exit 1
    end
  end

  def prepare_cache_dir(clean = false)
    if !File.directory?(COMMIT_CACHE_DIR)
      Dir.mkdir(COMMIT_CACHE_DIR)
    end
    if clean
      remove(GIT_STATE_TESTED_FILENAME)
      remove(PREVIOUS_COMMIT_MESSAGE_FILENAME)
    end
  end

  def last_tested_git_state
    if @last_tested_git_state.nil?
      @last_tested_git_state = FileUtils.read_text_file(GIT_STATE_TESTED_FILENAME,"")
      puts "---- Read old git state from file:\n#{@last_tested_git_state}\n" if @verbose
    end
    @last_tested_git_state
  end

  # Construct string representing git state; lazy initialized
  #
  def current_git_state
    if @current_git_state.nil?

      # Use full diff to determine if previous results are still valid
      current_diff_state,_ = scall("git diff -p")

      # Use brief status to test for untracked files and to report to user
      state,_= scall("git status -s")

      if state.include?('??')
        state,_ = scall("git status")
        raise ProgramException,"Unexpected repository state:\n#{state}"
      end
      @current_git_state = ""
      if !state.empty? || !current_diff_state.empty?
        @current_git_state = state + "\n" + current_diff_state + "\n"
      end
      puts "---- Determined current git state: #{@current_git_state}" if @verbose
    end
    @current_git_state
  end

  def strip_comments_from_string(m)
    m = m.strip
    lines = m.split("\n").collect{|x| x.rstrip}
    lines = lines.keep_if{|x| !x.start_with?('#')}
    lines.join("\n")
  end

  def convert_string_to_comments(s)
    s.split("\n").collect{|x| "# #{x}"}.join("\n") + "\n"
  end

  def previous_commit_message
    return nil if !File.exist?(PREVIOUS_COMMIT_MESSAGE_FILENAME)
    FileUtils.read_text_file(PREVIOUS_COMMIT_MESSAGE_FILENAME,"")
  end

  def edit_commit_message
    if !File.exist?(COMMIT_MESSAGE_FILENAME)
      status,_ = scall("git status")
      status = convert_string_to_comments(status)
      prior_msg = previous_commit_message
      content = COMMIT_MESSAGE_TEMPLATE_1
      if prior_msg
        content += COMMIT_MESSAGE_TEMPLATE_2 + convert_string_to_comments(prior_msg)
      end
      content += COMMIT_MESSAGE_TEMPLATE_3 + status
      FileUtils.write_text_file(COMMIT_MESSAGE_FILENAME,content)
    end

    TextEditor.new(COMMIT_MESSAGE_FILENAME).edit

    message = FileUtils.read_text_file(COMMIT_MESSAGE_FILENAME)
  end

  def commit_is_necessary
    !current_git_state().empty?
  end


  def perform_commit_if_nec
    return if !commit_is_necessary
    perform_commit_with_message(edit_commit_message)
  end

  def perform_commit_with_message(message)
    stripped = nil
    if message
        stripped = strip_comments_from_string(message)
    end

    raise(ProgramException,"Commit message empty") if !stripped
    if !(stripped =~ /#\d+/)
      raise(ProgramException,"No issue numbers found in commit message")
    end
    FileUtils.write_text_file(COMMIT_MESSAGE_STRIPPED_FILENAME,stripped)

    if system("git commit -a --file=#{COMMIT_MESSAGE_STRIPPED_FILENAME}")
      # Dispose of the commit message, since it has made its way into a successful commit
      remove(COMMIT_MESSAGE_FILENAME)
      remove(COMMIT_MESSAGE_STRIPPED_FILENAME)
      # Throw out previous tested state, since commit has occurred
      remove(GIT_STATE_TESTED_FILENAME)
      FileUtils.write_text_file(PREVIOUS_COMMIT_MESSAGE_FILENAME,stripped)
    else
      raise(ProgramException,"Git commit failed; error #{$?}")
    end
  end

  def parse_arguments(argv)
    p = Trollop::Parser.new do
      banner <<-EOS
      Runs unit tests, generates commit for this project
      EOS
      opt :clean, "clean projects before running tests"
      opt :detail, "display lots of detail"
      opt :verbose, "display progress"
      opt :omit_tests,"omit tests"
      opt :omit_java, "omit 'plain old' Java unit tests", :short => 'j'
      opt :testonly,"perform unit tests only, without generating commit"
    end

    Trollop::with_standard_exception_handling p do
      p.parse argv
    end
  end

  # Run the unit tests, if we haven't already successfully run them
  # for this repository state (and user isn't explicitly omitting them)
  #
  def run_unit_tests
    return if @options[:omit_tests]

    if current_git_state == last_tested_git_state
      return
    end
    if true
      puts "...unit tests not yet supported, omitting"
      return
    end

    puts "...this project state has not been tested, running unit tests" if @verbose

    options = " -t"
    options = options + " -c" if @options[:clean]
    options = options + " -j" if @options[:omit_java]

    output,_ = runcmd("runtests.rb#{options}","Running unit tests")

    # Write the current git state to the cache, to indicate we've tested it
    FileUtils.write_text_file(GIT_STATE_TESTED_FILENAME,@current_git_state)
  end

  def runcmd(cmd,message=nil)
    filt_message = message || "no message given"
    if !@verbose
      echo filt_message if message
    else
      echo(sprintf("%-40s (%s)",filt_message,cmd))
    end
    output,success = scall(cmd,false)
    if !success
      raise ProgramException,"Problem executing command: (#{filt_message}) #{cmd};\n#{output}"
    end
    if @detail
      puts output
      puts
    end
    [output,success]
  end

  def echo(msg)
    puts msg
  end

  def remove(file)
    FileUtils.rm(file) if File.exist?(file)
  end

end

if __FILE__ == $0
  App.new.run(ARGV)
end

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

  # Determine the git repository root directory, and from it,
  # the commit cache directory
  #
  root_dir,_ = scall("git rev-parse --show-toplevel")
  root_dir.chomp!
  REPO_ROOT_DIR = root_dir

  COMMIT_CACHE_DIR = File.join(REPO_ROOT_DIR, ".commit_cache")

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

  # Enter commit message; include an issue number prefixed with '#'.
  #            (close issue via 'fixes #', 'resolves #', 'closes #')
  EOS

  COMMIT_MESSAGE_TEMPLATE_2=<<-EOS.strip_heredoc

  # Previous commit's message:
  # --------------------------------------------------------------------------
  EOS


  COMMIT_MESSAGE_TEMPLATE_HISTORY=<<-EOS.strip_heredoc

  # Previous commits:
  # --------------------------------------------------------------------------
  EOS

  COMMIT_MESSAGE_TEMPLATE_3=<<-EOS.strip_heredoc

  # Git repository status:
  # --------------------------------------------------------------------------
  EOS

  MESSAGE_ONLY_TEXT = "# (Editing message only, not generating a commit)\n"

  def run(argv = nil)

    @options = parse_arguments(argv)
    @detail = @options[:detail]
    @verbose = @options[:verbose] || @detail
    @current_git_state = nil

    begin
      prepare_cache_dir()

      if @options[:message_only]
        edit_commit_message(true)
      else
        message = nil
        if commit_is_necessary
          message = edit_commit_message
        end
        perform_commit_with_message(message) if commit_is_necessary
      end

    rescue ProgramException => e
      puts "*** Aborted!  #{e.message}"
      exit 1
    end
  end

  def prepare_cache_dir()
    if !File.directory?(COMMIT_CACHE_DIR)
      Dir.mkdir(COMMIT_CACHE_DIR)
    end
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

  def edit_commit_message(edit_message_only = false)
    if !File.exist?(COMMIT_MESSAGE_FILENAME)
      status,_ = scall("git status")
      status = convert_string_to_comments(status)
      prior_msg = previous_commit_message
      content = COMMIT_MESSAGE_TEMPLATE_1
      if prior_msg
        content << COMMIT_MESSAGE_TEMPLATE_2 << convert_string_to_comments(prior_msg)
      end

      # Get the previous few log history lines, and append to show user
      # some issue numbers he may want
      hist,success = scall('git log --pretty=format:%s -4',false)
      if success
        content << COMMIT_MESSAGE_TEMPLATE_HISTORY + convert_string_to_comments(hist)
      end

      content << COMMIT_MESSAGE_TEMPLATE_3 + status
      FileUtils.write_text_file(COMMIT_MESSAGE_FILENAME,content)
    end

    # Add or remove 'message only' prefix as appropriate, BEFORE editing the file,
    # and again afterward
    # (so the 'message only' is really only information to the user, and not part of the
    # commit message)
    #
    insert_message_only(edit_message_only)
    TextEditor.new(COMMIT_MESSAGE_FILENAME).edit
    if edit_message_only
      insert_message_only(false)
    end

    message = FileUtils.read_text_file(COMMIT_MESSAGE_FILENAME)
  end

  def insert_message_only(add_message)
    content = FileUtils.read_text_file(COMMIT_MESSAGE_FILENAME)
    if content.start_with?(MESSAGE_ONLY_TEXT)
      content = content[MESSAGE_ONLY_TEXT.length..-1]
    end
    if add_message
      content = MESSAGE_ONLY_TEXT + content
    end
    FileUtils.write_text_file(COMMIT_MESSAGE_FILENAME,content,true)
  end

  def commit_is_necessary
    !current_git_state().empty?
  end

  def perform_commit_if_nec
    return if !commit_is_necessary
    perform_commit_with_message(edit_commit_message)
  end

  def perform_commit_with_message(message)
    find_merge_conflicts if !@options[:ignore_merge_conflicts]
    stripped = nil
    if message
      stripped = strip_comments_from_string(message)
    end

    raise(ProgramException,"Commit message empty") if !stripped
    if !(stripped =~ /#\d+/)
      raise ProgramException,"No issue numbers found in commit message"
    end

    FileUtils.write_text_file(COMMIT_MESSAGE_STRIPPED_FILENAME,stripped)

    if system("git commit -a --file=#{COMMIT_MESSAGE_STRIPPED_FILENAME}")
      # Dispose of the commit message, since it has made its way into a successful commit
      remove(COMMIT_MESSAGE_FILENAME)
      remove(COMMIT_MESSAGE_STRIPPED_FILENAME)
      FileUtils.write_text_file(PREVIOUS_COMMIT_MESSAGE_FILENAME,stripped)
    else
      raise(ProgramException,"Git commit failed; error #{$?}")
    end
  end

  def find_merge_conflicts
    # Search for merge conflict markers; escape them to avoid shell expansion
    # Avoid expressing merge conflict markers within this source file, to prevent
    # spurious marge conflict detection on this file
    cmd = "grep -nrI -e \"#{"<<<"}#{"<<< "}\" -e \"#{">>>"}#{">>> "}\" \"#{REPO_ROOT_DIR}\""
    results,success = scall(cmd,false)
    return if !success
    die "Unprocessed merge conflict:\n#{results}"
  end

  def parse_arguments(argv)
    p = Trollop::Parser.new do
      banner <<-EOS
      Runs unit tests, generates commit for this project
      EOS
      opt :detail, "display lots of detail"
      opt :verbose, "display progress"
      opt :message_only, "edit commit message without generating commit", :short => 'm'
      opt :ignore_merge_conflicts, "ignore any merge conflicts", :short => 'M'
    end

    Trollop::with_standard_exception_handling p do
      p.parse argv
    end
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

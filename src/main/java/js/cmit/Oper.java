package js.cmit;

import static js.base.Tools.*;

import java.io.File;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.util.List;

import gitutil.gen.FileEntry;
import js.app.AppOper;
import js.app.CmdLineArgs;
import js.base.BasePrinter;
import js.base.SystemCall;
import js.file.Files;
import js.gitutil.GitRepo;
import js.parsing.RegExp;
import js.system.SystemUtil;

public class Oper extends AppOper {

  @Override
  protected String getHelpDescription() {
    return "records a commit message and makes a git commit";
  }

  @Override
  public String userCommand() {
    return null;
  }

  @Override
  public void perform() {
    if (cmdLineArgs().get(CLARG_MESSAGEONLY)) {
      editCommitMessage(true);
    } else {
      String message = null;
      if (!gitRepo().unmergedFiles().isEmpty())
        reportError("There are unmerged files!", gitRepo().unmergedFiles());
      if (!gitRepo().untrackedFiles().isEmpty()) {
        String errMessage = constructErrorMessage("There are untracked files!", gitRepo().untrackedFiles());
        if (!cmdLineArgs().get(CLARG_UNTRACKED))
          setError(errMessage);
        pr(errMessage);
        pr("...allowing anyways.");
      }
      if (!gitRepo().markedFiles().isEmpty()) {
        reportError("There are marked files!", gitRepo().markedFiles());
      }
      if (commit_is_necessary()) {
        message = editCommitMessage(false);
        performCommitWithMessage(message);
      }
    }
  }

  private String constructErrorMessage(String prompt, List<FileEntry> files) {
    BasePrinter p = new BasePrinter();
    p.pr(prompt);
    p.indent();
    for (FileEntry f : files)
      p.pr(gitRepo().fileRelativeToDirectory(f.path(), null));
    return p.toString();
  }

  private void reportError(String prompt, List<FileEntry> files) {
    setError(constructErrorMessage(prompt, files));
  }

  private static final String CLARG_MESSAGEONLY = "messageonly";
  private static final String CLARG_IGNORECONFLICT = "ignoreconflict";
  private static final String CLARG_UNTRACKED = "untracked";

  @Override
  public void addCommandLineArgs(CmdLineArgs ca) {
    ca.add(CLARG_MESSAGEONLY).desc("Edit commit message without generating commit").shortName("m");
    ca.add(CLARG_IGNORECONFLICT).desc("Ignore any merge conflicts").shortName("M");
    ca.add(CLARG_UNTRACKED).desc("Allow untracked files").shortName("u");
  }

  // The commit message to be used for the next commit, it is edited by the user,
  // stored in this file, and deleted when commit succeeds
  //
  private static final String COMMIT_MESSAGE_FILENAME = "editor_message.txt";

  // The commit message, after all comments are stripped; this is what is actually committed
  //
  private static final String COMMIT_MESSAGE_STRIPPED_FILENAME = "editor_message_stripped.txt";
  private static final String PREVIOUS_COMMIT_MESSAGE_FILENAME = "previous_editor_message.txt";

  private static final String MESSAGE_ONLY_TEXT = "# (Editing message only, not generating a commit)\n";

  private File cacheDir() {
    if (mCacheDir == null)
      mCacheDir = files().mkdirs(gitRepo().absoluteFile("_SKIP_gitdiff_backups/cmit_cache"));
    return mCacheDir;
  }

  private File mCacheDir;

  private String convertStringToGitComments(String s) {
    StringBuilder sb = new StringBuilder();
    for (String line : split(s, '\n')) {
      sb.append("# ");
      sb.append(line);
      sb.append('\n');
    }
    return sb.toString();
  }

  private String previousCommitMessage() {
    return Files.readString(cacheFile(PREVIOUS_COMMIT_MESSAGE_FILENAME), "");
  }

  private String stripCommentsFromString(String m) {
    boolean vertSpacingRequested = false;
    StringBuilder sb = new StringBuilder();
    for (String line : split(m, '\n')) {
      if (line.startsWith("#"))
        continue;
      if (line.isEmpty()) {
        vertSpacingRequested = true;
        continue;
      }
      if (vertSpacingRequested) {
        vertSpacingRequested = false;
        sb.append('\n');
      }
      sb.append(line);
      sb.append('\n');
    }
    return sb.toString();
  }

  private String readResource(String relPath) {
    return Files.readString(this.getClass(), relPath);
  }

  private String editCommitMessage(boolean editMessageOnly) {
    File file = cacheFile(COMMIT_MESSAGE_FILENAME);
    String prevContent = Files.readString(file, "").trim();

    if (prevContent.isEmpty()) {
      String status = new SystemCall().arg("git", "status").systemOut();
      status = convertStringToGitComments(status);
      String prior_msg = previousCommitMessage();
      String content = readResource("commit_message_1.txt");

      if (!prior_msg.isEmpty()) {
        content = content + readResource("commit_message_2.txt") + convertStringToGitComments(prior_msg);
      }

      // Get the previous few log history lines, and append to show user
      //  some issue numbers he may want
      SystemCall s = new SystemCall().arg("git", "log", "--pretty=format:%s", "-4");
      String hist = s.systemOut();
      if (s.exitCode() == 0)
        content = content + readResource("commit_message_history.txt") + convertStringToGitComments(hist);

      content = content + readResource("commit_message_3.txt") + status;
      files().writeString(file, content);
    }

    //
    // Add or remove 'message only' prefix as appropriate, BEFORE editing the file,
    // and again afterward
    // (so the 'message only' is really only information to the user, and not part of the
    // commit message)
    //
    insertMessageOnly(file, editMessageOnly);

    SystemUtil.runUnchecked(() -> {
      Process p = Runtime.getRuntime().exec("/bin/bash");
      OutputStream stdin = p.getOutputStream();
      PrintWriter pw = new PrintWriter(stdin);
      pw.println("vi " + file + " < /dev/tty > /dev/tty");
      pw.close();
      p.waitFor();
    });

    if (editMessageOnly)
      insertMessageOnly(file, false);

    return Files.readString(file);
  }

  private File cacheFile(String relPath) {
    return new File(cacheDir(), relPath);
  }

  private boolean commit_is_necessary() {
    return gitRepo().workingTreeModified();
  }

  private void performCommitWithMessage(String message) {
    if (!cmdLineArgs().get(CLARG_IGNORECONFLICT)) {
      findMergeConflicts();
    }
    String stripped = null;
    if (!nullOrEmpty(message))
      stripped = stripCommentsFromString(message);

    if (nullOrEmpty(stripped))
      setError("Commit message is empty!");

    if (!RegExp.matcher("#\\d+", stripped).find())
      setError("No issue numbers were found in the commit message");

    files().writeString(cacheFile(COMMIT_MESSAGE_STRIPPED_FILENAME), stripped);

    if (stripped.length() > 3000)
      setError("The commit message is too long!");

    new SystemCall()//
        .arg("git", "commit", "-a", "--file=" + cacheFile(COMMIT_MESSAGE_STRIPPED_FILENAME))//
        .assertSuccess();
    files().deleteFile(cacheFile(COMMIT_MESSAGE_FILENAME));
    files().deleteFile(cacheFile(COMMIT_MESSAGE_STRIPPED_FILENAME));
    files().writeString(cacheFile(PREVIOUS_COMMIT_MESSAGE_FILENAME), stripped);
  }

  private void findMergeConflicts() {
    String result = new SystemCall()//
        .arg("git", "diff", "--name-only", "--diff-filter=U")//
        .assertSuccess().systemOut();
    if (result.isEmpty())
      return;
    setError("Unprocessed merge conflict(s):", INDENT, result);
  }

  private String insertMessageOnly(File messageFile, boolean add_message) {
    String content = Files.readString(messageFile, "");
    content = chompPrefix(content, MESSAGE_ONLY_TEXT);
    if (add_message)
      content = MESSAGE_ONLY_TEXT + content;
    files().writeString(messageFile, content);
    return content;
  }

  private GitRepo gitRepo() {
    if (mGitRepo == null) {
      mGitRepo = new GitRepo(Files.currentDirectory());
    }
    return mGitRepo;
  }

  private GitRepo mGitRepo;

}
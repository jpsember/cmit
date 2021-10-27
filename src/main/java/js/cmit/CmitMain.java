package js.cmit;

import static js.base.Tools.*;

import js.app.App;

public class CmitMain extends App {

  public static void main(String[] args) {
    loadTools();
    App app = new CmitMain();
    app.startApplication(args);
    app.exitWithReturnCode();
  }

  @Override
  public String getVersion() {
    return "1.0";
  }

  @Override
  protected void registerOperations() {
    registerOper(new Oper());
  }

  @Override
  public boolean supportArgsFile() {
    return false;
  }

}

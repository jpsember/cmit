#!/usr/bin/env bash
set -e

APP=cmit
MVN=$HOME/.m2/repository
DIR=$(pwd)

###### Custom statements start ##### {~custom1:
###### Custom statements end   ##### ~}

if [ -f "target/classes/js/cmit/CmitMain.class" ]; then
  APPLOC="target/classes"
else
  APPLOC="$MVN/com/jsbase/$APP/1.0/$APP-1.0.jar"
fi

java -Dfile.encoding=UTF-8 -classpath $APPLOC:$MVN/commons-io/commons-io/2.6/commons-io-2.6.jar:$MVN/com/jsbase/base/1.0/base-1.0.jar:$MVN/com/jsbase/gitutil/1.0/gitutil-1.0.jar js.cmit/CmitMain "$@"

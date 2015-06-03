#!/usr/bin/env bash
unset CDPATH

ACTION=$1
export PATH=$HOME/bin:$PATH

# --------------
# - Detect number of usable CPUs.
#
# NOTE: if a single machine gets leased multiple times, this will
# probably suck.
detect_cpu_count() {
  if [ "x$CPUS" = "x" ]; then
    # Windows standard environment variable
    CPUS="$NUMBER_OF_PROCESSORS"
  fi

  if [ "x$CPUS" = "x" ]; then
    # Linux
    CPUS=`getconf _NPROCESSORS_ONLN 2>/dev/null`
  fi

  if [ "x$CPUS" = "x" ]; then
    # FreeBSD
    CPUS=`getconf NPROCESSORS_ONLN 2>/dev/null`
  fi

  if [ "x$CPUS" = "x" ]; then
    # nothing helped
    CPUS="1"
  fi
}
detect_cpu_count

# --------------
# Run a program in the background with some console output
waiting_progress() {
  RUNPID=$!
  trap "kill $RUNPID 2> /dev/null" EXIT
  while kill -0 $RUNPID 2> /dev/null; do
    sleep $1
    echo -n "."
  done
  trap - EXIT
  wait $RUNPID
  RESULT=$?
}

# --------------
# - Build a GHC commit that has been pushed to the repository
#
# NOTE: this function assumes that there won't be concurrent versions
# of the same build running at once. Generally this shouldn't happen,
# although builds could get restarted or something. Also, in
# Harbormaster, this build step should have a dependency to wait for
# all previous commits to build.
build_ghc_commit() {
  RET=0
  BASEDIR="/srv"
  BDIR="$BASEDIR/builds/commits/r$REPO/B$BUILDID-$COMMIT"
  cd $BASEDIR
  mkdir -p $BDIR

  # -- Setup git repositories
  echo "Now building B$BUILDID: commit r$REPO$COMMIT"
  echo    " - Base directory: $BDIR"
  echo -n " - Cloning repository..."
  TEMPLOG=`mktemp /tmp/phab-git-log-XXXXXX.txt`
  START=$(date +%s.%N)
  (git clone git://git.haskell.org/ghc.git $BDIR > $TEMPLOG 2>&1) &
  waiting_progress 5
  END=$(date +%s.%N)
  if [ "$RESULT" != "0" ]; then
    echo "ERROR: Couldn't clone git repository!"
    echo "ERROR: Couldn't clone git repository!" >&2
    rm -rf $TEMPLOG $BDIR
    exit 1
  fi
  echo " OK (took about" $(echo "$END - $START" | bc) "seconds)"
  mv $TEMPLOG $BDIR/build-log.txt
  cd $BDIR

  # -- Clone submodules
  echo -n " - Updating HEAD and grabbing submodules..."
  START=$(date +%s.%N)
  (git checkout $COMMIT >> build-log.txt 2>&1 && \
   git submodule init   >> build-log.txt 2>&1 && \
   git submodule update >> build-log.txt 2>&1) &
  waiting_progress 5
  END=$(date +%s.%N)
  if [ "$RESULT" != "0" ]; then
    echo "ERROR: Couldn't clone git repository!"
    echo "ERROR: Couldn't clone git repository! Logs:" >&2
    cat build-log.txt >&2
    RET=1
  else
    echo " OK (took about" $(echo "$END - $START" | bc) "seconds)"

    # -- Begin building
    echo
    echo "OK, starting build on" $(date)
    echo    " - Using $CPUS CPUs on" $(uname -a)
    echo -n " - Running validate..."
    START=$(date +%s.%N)
    (./validate --quiet >> build-log.txt 2>&1) &
    waiting_progress 20
    END=$(date +%s.%N)
    if [ "$RESULT" != "0" ]; then
      echo "ERROR: validate failed!"
      echo "ERROR: validate failed! Last 30 lines of log file:" >&2
      tail -30 build-log.txt >&2
      RET=1
    else
      echo " OK (took about" $(echo "$END - $START" | bc) "seconds)"
    fi
  fi

  ## -- Done
  echo -n " - LZMA compressing full build logs..."
  START=$(date +%s.%N)
  (xz -9 build-log.txt) &
  waiting_progress 5
  END=$(date +%s.%N)
  if [ "$RESULT" != "0" ]; then
    echo "ERROR: log compression failed!"
    echo "ERROR: log compression failed!" >&2
    RET=1
  else
    echo " OK (took about" $(echo "$END - $START" | bc) "seconds)"
    mv build-log.txt.xz /srv/logs/r$REPO-B$BUILDID-$COMMIT-logs.txt.xz
  fi

  if [ -f "testsuite_summary.txt" ]; then
    echo
    echo "================== Testsuite summary =================="
    cat testsuite_summary.txt
  fi

  rm -rf $BDIR
  exit $RET
}

# --------------
# - Build a GHC patch that has been submitted with Arcanist
#
build_ghc_diff() {
  RET=0
  BASEDIR="/srv"
  BDIR="$BASEDIR/builds/patches/r$REPO/B$BUILDID-D$REVISION-$DIFF"
  cd $BASEDIR
  mkdir -p $BDIR

  # -- Setup git repositories
  echo "Now building B$BUILDID: patch r$REPO/D$REVISION:$DIFF"
  echo    " - Base directory: $BDIR"
  echo -n " - Cloning repository..."
  TEMPLOG=`mktemp /tmp/phab-git-log-XXXXXX.txt`
  START=$(date +%s.%N)
  (git clone git://git.haskell.org/ghc.git $BDIR > $TEMPLOG 2>&1) &
  waiting_progress 5
  END=$(date +%s.%N)
  if [ "$RESULT" != "0" ]; then
    echo "ERROR: Couldn't clone git repository!"
    echo "ERROR: Couldn't clone git repository!" >&2
    rm -rf $TEMPLOG $BDIR
    exit 1
  fi
  echo " OK (took about" $(echo "$END - $START" | bc) "seconds)"
  mv $TEMPLOG $BDIR/build-log.txt
  cd $BDIR

  # -- Clone submodules
  echo -n " - Updating HEAD and grabbing submodules..."
  START=$(date +%s.%N)
  (git checkout $COMMIT >> build-log.txt 2>&1 && \
   git submodule init   >> build-log.txt 2>&1 && \
   git submodule update >> build-log.txt 2>&1) &
  waiting_progress 5
  END=$(date +%s.%N)
  if [ "$RESULT" != "0" ]; then
    echo "ERROR: Couldn't clone git repository!"
    echo "ERROR: Couldn't clone git repository! Logs:" >&2
    cat build-log.txt >&2
    RET=1
  else
    echo " OK (took about" $(echo "$END - $START" | bc) "seconds)"

    # -- Apply patches
    echo -n " - Applying diff $DIFF via Arcanist... "
    START=$(date +%s.%N)
    arc patch --force --nocommit --nobranch --diff $DIFF >> build-log.txt 2>&1
    END=$(date +%s.%N)
    echo "OK (took about" $(echo "$END - $START" | bc) "seconds)"

    # -- Begin building
    echo
    echo "OK, starting build on" $(date)
    echo    " - Using $CPUS CPUs on" $(uname -a)
    echo -n " - Running validate..."
    START=$(date +%s.%N)
    (./validate --quiet >> build-log.txt 2>&1) &
    waiting_progress 20
    END=$(date +%s.%N)
    if [ "$RESULT" != "0" ]; then
      echo "ERROR: validate failed!"
      echo "ERROR: validate failed! Last 30 lines of log file:" >&2
      tail -30 build-log.txt >&2
      RET=1
    else
      echo " OK (took about" $(echo "$END - $START" | bc) "seconds)"
    fi
  fi

  ## -- Done
  echo -n " - LZMA compressing full build logs..."
  START=$(date +%s.%N)
  (xz -9 build-log.txt) &
  waiting_progress 5
  END=$(date +%s.%N)
  if [ "$RESULT" != "0" ]; then
    echo "ERROR: log compression failed!"
    echo "ERROR: log compression failed!" >&2
    RET=1
  else
    echo " OK (took about" $(echo "$END - $START" | bc) "seconds)"
    mv build-log.txt.xz /srv/logs/r$REPO-B$BUILDID-D$REVISION-$DIFF-logs.txt.xz
  fi

  if [ -f "testsuite_summary.txt" ]; then
    echo
    echo "================== Testsuite summary =================="
    cat testsuite_summary.txt

    if grep -q '^TEST=' testsuite_summary.txt; then
        # re-run tests w/ high verbosity
        make -C testsuite VERBOSE=4 $(grep '^TEST=' testsuite_summary.txt)
    fi
  fi

  rm -rf $BDIR
  exit $RET
}

# --------------
# -- Main

if [ "x$ACTION" == "xcommit" ]; then
  REPO=$2
  BUILDID=$3
  COMMIT=$4
  build_ghc_commit
fi

if [ "x$ACTION" == "xdiff" ]; then
  REPO=$2
  BUILDID=$3
  REVISION=$4
  DIFF=$5
  build_ghc_diff
fi

echo "Invalid action: $ACTION"; exit 1

# Local Variables:
# fill-column: 80
# indent-tabs-mode: nil
# c-basic-offset: 2
# buffer-file-coding-system: utf-8-unix
# End:

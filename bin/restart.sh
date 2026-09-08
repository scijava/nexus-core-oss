#!/bin/sh

# Stops and restarts the Nexus service, waiting for each transition to
# actually complete by polling for the real process (not the launcher's
# PID file, which has been observed to go stale, and not systemctl's own
# state, which doesn't get updated when the process is managed via the
# underlying /etc/init.d/nexus script rather than systemctl directly).
#
# Both functions match on "nexus-repository", a substring of the jar name
# under either edition (sonatype-nexus-repository-*.jar for Community, or
# nexus-repository-core-*.jar for Core OSS built by this project) -- not
# "org.sonatype.nexus", which never actually appears in either edition's
# real command line (confirmed 2026-09-06 by checking directly against
# the running process). See init.d/nexus for the same fix applied to its
# own process-matching.

# Wait up to 1 minute for a service to start up.
waitForStart() {
  name=$1
  user=$2
  pattern=$3
  for _ in $(seq 1 60)
  do
    ! ps aux | grep "^$user\b" | grep -q "$pattern" || break
    sleep 1
  done
  if ! ps aux | grep "^$user\b" | grep -q "$pattern"
  then
    echo "[ERROR] $name did not start up after 60 seconds!"
    exit 2
  fi
}

# Wait up to 1 minute for a service to shut down.
waitForStop() {
  name=$1
  user=$2
  pattern=$3
  for _ in $(seq 1 60)
  do
    ps aux | grep "^$user\b" | grep -q "$pattern" || break
    sleep 1
  done
  if ps aux | grep "^$user\b" | grep -q "$pattern"
  then
    echo "[ERROR] $name did not shut down after 60 seconds:"
    ps aux | grep "^$user\b" | grep "$pattern"
    exit 1
  fi
}

# `service nexus stop` and `systemctl stop nexus` can silently no-op if a
# stale systemd unit's tracked state has drifted out of sync with the
# process actually being managed via /etc/init.d/nexus directly (confirmed
# 2026-09-06 on a box with exactly this drift). /etc/init.d/nexus itself
# (which just execs the real launcher as the service user, no systemd
# involved) is the only one that reliably reflects and controls the
# actual process, so use it directly for both the stop below and the
# start already below that -- never `service`/`systemctl` for this.
/etc/init.d/nexus stop
waitForStop Nexus nexus nexus-repository
sleep 5

/etc/init.d/nexus start
waitForStart Nexus nexus nexus-repository

#!/bin/sh
set -e

# Builds the latest Nexus Repository Core OSS release and deploys it via
# a symlink swap at /opt/nexus3, so the built assembly's own bin/nexus
# launcher script needs no modification, and rollback is just repointing
# the symlink back.
#
# Cheaply checks the latest release-* tag (bin/latest-tag.sh) against
# what's currently deployed at /opt/nexus3 before doing anything else,
# and exits immediately if they already match. Only a real version
# change pays for the full JDK/Maven/Node/mvn build in build.sh and the
# resulting service restart -- so this is safe to run routinely (e.g.
# from cron) without disturbing an already-current, already-running
# Nexus.
#
# Usage:
#   bin/upgrade.sh --dry-run   # if an upgrade is available, stage the
#                              # build and report what would happen,
#                              # touching nothing live
#   bin/upgrade.sh             # if an upgrade is available, actually cut
#                              # over -- fails fast if not run as root
#                              # (needed for the /opt/ staging, the
#                              # symlink swap, and the service restart
#                              # regardless of who owns /opt/nexus-public).
#                              # Do not run this until you mean it. See
#                              # README.md for the manual equivalent if
#                              # you'd rather drive this by hand.

dir=$(dirname "$0")
dry_run=false
case "$1" in
  --dry-run) dry_run=true ;;
esac

log() { echo "[upgrade.sh] $*" >&2; }

current_target=$(readlink -f /opt/nexus3 2>/dev/null || true)
current_version=$(echo "$current_target" | sed -n 's#.*/nexus-core-##p')
latest_version=$("$dir"/latest-tag.sh)

if [ "$latest_version" = "$current_version" ]; then
  log "Already up to date: $current_target matches the latest release (release-$latest_version). Nothing to do."
  exit 0
fi

# Only the real cutover needs root (staging under /opt/, the symlink swap,
# and the service restart all require it regardless of who owns
# /opt/nexus-public) -- --dry-run stays runnable by anyone, same as
# build.sh, so it's still safe to use for ad-hoc verification.
if ! $dry_run; then
  test "$(whoami)" = root || { log "ERROR: please run as root."; exit 1; }
fi

assembly_dir=$("$dir"/build.sh | tail -1)
test -d "$assembly_dir" || { log "ERROR: build.sh did not report a valid assembly directory."; exit 1; }

jar=$(find "$assembly_dir/bin" -maxdepth 1 -iname "nexus-repository-core-*.jar" | head -1)
test -n "$jar" || { log "ERROR: no nexus-repository-core-*.jar found in $assembly_dir/bin."; exit 1; }
version=$(basename "$jar" .jar | sed 's/^nexus-repository-core-//')
test -n "$version" || { log "ERROR: could not determine version from $jar."; exit 1; }

install_dir="/opt/nexus-core-$version"

if $dry_run; then
  log "--dry-run: built $version successfully ($assembly_dir)."
  log "Without --dry-run, this would now (requires root, touches nothing so far):"
  log "  1. Stage it at $install_dir"
  log "  2. Repoint /opt/nexus3 ($current_target) -> $install_dir"
  log "  3. Run $dir/restart.sh to cleanly stop/start the Nexus service"
  log "  4. Verify exactly one process is running afterward"
  exit 0
fi

log "Staging $assembly_dir -> $install_dir"
rm -rf "$install_dir"
cp -a "$assembly_dir" "$install_dir"
log "Current /opt/nexus3 -> $current_target"
log "New version staged at $install_dir"

log "Repointing /opt/nexus3 -> $install_dir"
ln -sfn "$install_dir" /opt/nexus3

log "Restarting Nexus..."
"$dir"/restart.sh

# "nexus-repository", not "sonatype-nexus-repository": the latter doesn't
# match Core OSS's jar name (nexus-repository-core-*.jar), only Community's
# (sonatype-nexus-repository-*.jar) -- see service/sysv/nexus for the same
# fix applied to its own process-matching, and why it matters.
running=$(pgrep -cf nexus-repository || true)
if [ "$running" != "1" ]; then
  log "ERROR: expected exactly one Nexus process after restart, found $running."
  log "Previous version was at $current_target -- to roll back:"
  log "  ln -sfn $current_target /opt/nexus3 && $dir/restart.sh"
  exit 1
fi

log "Upgrade complete: $current_target -> $install_dir"

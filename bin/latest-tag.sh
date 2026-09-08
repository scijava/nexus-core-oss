#!/bin/sh
set -e

# Prints (to stdout) the version of the latest release-* tag in the
# nexus-public checkout at $NEXUS_PUBLIC_DIR (default /opt/nexus-public),
# e.g. "3.96.0-09" for tag "release-3.96.0-09".
#
# Deliberately cheap: only touches git (a tag fetch + local sort), none
# of the JDK/Maven/Node/build machinery in build.sh. Used by build.sh (to
# know what to check out) and upgrade.sh (to decide whether a build is
# even needed) so that tag-selection logic lives in exactly one place.

nexus_public_dir=${NEXUS_PUBLIC_DIR:-/opt/nexus-public}

cd "$nexus_public_dir"
git fetch --tags --quiet
latest_tag=$(git tag --list 'release-*' | sort -V | tail -1)
test -n "$latest_tag" || { echo "[latest-tag.sh] ERROR: no release-* tags found." >&2; exit 1; }
echo "${latest_tag#release-}"

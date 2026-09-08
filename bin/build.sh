#!/bin/sh
set -e

# Builds Nexus Repository Core OSS from source. Prints the path to the
# resulting assembly directory (a self-contained bin/etc/deploy layout,
# structurally equivalent to Sonatype's official unix-archive distributions)
# on stdout as the last line on success; everything else goes to stderr.
#
# Usable standalone ("just build from source, don't deploy anything") or
# as the first step of bin/upgrade.sh.
#
# Self-contained by design: bootstraps its own JDK/Maven/Node into hidden
# directories alongside the checkout rather than assuming a particular
# user's environment is pre-configured (this may run as an unprivileged
# service user via a cron-driven upgrade.sh, not always an interactive
# admin shell).
#
# Background on the two non-obvious requirements below: both were found
# by actually attempting the build against release-3.96.0-09 on
# 2026-09-04, not by trusting the (older, and in these two respects
# wrong) build instructions floating around for this project.

nexus_public_dir=${NEXUS_PUBLIC_DIR:-/opt/nexus-public}

log() { echo "[build.sh] $*" >&2; }

# -- JDK 25+ --
#
# release-3.96.0-09's Maven enforcer plugin requires JDK 25+ (older
# releases required only 21; Sonatype raised the floor at some point
# between 3.89.0-09 and 3.96.0-09). Rather than depend on a specific JDK
# being installed system-wide -- fragile, and would need root to fix if
# wrong -- we bootstrap our own into the checkout.
build_jdk_dir="$nexus_public_dir/.build-jdk"
jdk_ok() {
  test -x "$build_jdk_dir/bin/java" &&
    "$build_jdk_dir/bin/java" -version 2>&1 | grep -q '"25\.'
}
if ! jdk_ok; then
  log "Fetching Temurin JDK 25..."
  rm -rf "$build_jdk_dir" "$build_jdk_dir.tmp"
  mkdir -p "$build_jdk_dir.tmp"
  curl -fsL "https://api.adoptium.net/v3/binary/latest/25/ga/linux/x64/jdk/hotspot/normal/eclipse" \
    -o "$build_jdk_dir.tmp/jdk.tar.gz"
  tar xzf "$build_jdk_dir.tmp/jdk.tar.gz" -C "$build_jdk_dir.tmp" --strip-components=1
  rm -f "$build_jdk_dir.tmp/jdk.tar.gz"
  mv "$build_jdk_dir.tmp" "$build_jdk_dir"
fi
jdk_ok || { log "ERROR: JDK 25 bootstrap failed."; exit 1; }
export JAVA_HOME="$build_jdk_dir"
export PATH="$JAVA_HOME/bin:$PATH"

# -- Maven 3.9+ --
#
# This checkout has no mvnw wrapper script, despite what its own README
# claims. The enforcer above also requires Maven itself to be 3.9+.
build_mvn_dir="$nexus_public_dir/.build-maven"
mvn_ok() {
  test -x "$build_mvn_dir/bin/mvn" &&
    "$build_mvn_dir/bin/mvn" -version 2>&1 | grep -q "Apache Maven 3\.9"
}
if ! mvn_ok; then
  log "Fetching Maven 3.9.9..."
  rm -rf "$build_mvn_dir" "$build_mvn_dir.tmp"
  mkdir -p "$build_mvn_dir.tmp"
  # archive.apache.org (not dlcdn.apache.org, which only mirrors the
  # single latest release per line and 404s on any pinned older version)
  curl -fsL "https://archive.apache.org/dist/maven/maven-3/3.9.9/binaries/apache-maven-3.9.9-bin.tar.gz" \
    -o "$build_mvn_dir.tmp/maven.tar.gz"
  tar xzf "$build_mvn_dir.tmp/maven.tar.gz" -C "$build_mvn_dir.tmp" --strip-components=1
  rm -f "$build_mvn_dir.tmp/maven.tar.gz"
  mv "$build_mvn_dir.tmp" "$build_mvn_dir"
fi
mvn_ok || { log "ERROR: Maven 3.9 bootstrap failed."; exit 1; }
mvn="$build_mvn_dir/bin/mvn"

# -- Node.js + corepack --
#
# frontend-maven-plugin needs a working `corepack` to resolve the
# project's pinned yarn@4.9.1 (declared via package.json's
# "packageManager" field). A prior build attempt's log
# (target/../build.log, now stale) shows this failing with
# `yarn install --immutable`, because the committed yarn.lock doesn't
# match package.json in this public export (drifted from the private
# workspace it was generated in) -- hence `yarn install` below, no
# --immutable.
build_node_dir="$nexus_public_dir/.build-node"
node_ok() { test -x "$build_node_dir/bin/corepack"; }
if ! node_ok; then
  log "Fetching Node.js LTS..."
  rm -rf "$build_node_dir" "$build_node_dir.tmp"
  mkdir -p "$build_node_dir.tmp"
  node_version=$(curl -fsL https://nodejs.org/dist/index.json | \
    python3 -c "import json,sys; print(next(r['version'] for r in json.load(sys.stdin) if r['lts']))")
  curl -fsL "https://nodejs.org/dist/$node_version/node-$node_version-linux-x64.tar.xz" \
    -o "$build_node_dir.tmp/node.tar.xz"
  tar xJf "$build_node_dir.tmp/node.tar.xz" -C "$build_node_dir.tmp" --strip-components=1
  rm -f "$build_node_dir.tmp/node.tar.xz"
  mv "$build_node_dir.tmp" "$build_node_dir"
fi
node_ok || { log "ERROR: Node.js bootstrap failed."; exit 1; }
export PATH="$build_node_dir/bin:$PATH"
corepack enable --install-directory "$build_node_dir/bin"

# -- Checkout latest release tag --
#
# Tag selection lives in latest-tag.sh, not duplicated here, so
# upgrade.sh can cheaply answer "is a build even needed?" without paying
# for the JDK/Maven/Node bootstrap above.
export NEXUS_PUBLIC_DIR="$nexus_public_dir"
version=$("$(dirname "$0")/latest-tag.sh")
log "Checking out release-$version..."
cd "$nexus_public_dir"
git checkout --quiet "release-$version"

# -- Yarn linker mode --
#
# This checkout has no .yarnrc.yml either, despite the pinned
# "packageManager": "yarn@4.9.1" in package.json implying one should
# exist. Without it, Yarn 4 defaults to PnP (Plug'n'Play) linker mode,
# which breaks frontend-maven-plugin: PnP's strict module resolution
# doesn't know about the plugin's own independently-managed
# target/node/node_modules/corepack, and refuses to let it load
# ("tried to access corepack, but it isn't declared in your
# dependencies"). node-modules linking avoids this entirely.
if [ ! -f .yarnrc.yml ]; then
  log "Writing .yarnrc.yml (nodeLinker: node-modules)..."
  echo "nodeLinker: node-modules" > .yarnrc.yml
fi
rm -f .pnp.cjs .pnp.loader.mjs
rm -rf .yarn/unplugged .yarn/install-state.gz .yarn/cache

log "Running yarn install..."
corepack yarn install

# -- The actual build --
log "Running Maven build (this takes a few minutes)..."
"$mvn" -Ppublic -DskipTests -Dnpm.skipTests=true clean install

assembly_dir="$nexus_public_dir/public/selfhosted/assemblies/nexus-repository-core/target/assembly"
test -d "$assembly_dir" || { log "ERROR: expected assembly directory not found: $assembly_dir"; exit 1; }

# maven-assembly-plugin's exploded "assembly" directory output doesn't
# carry the executable bit the way extracting an official tar.gz
# distribution would (that comes from permission bits stored in the
# archive itself, which `tar x` restores -- there's no archive here).
# Confirmed 2026-09-06: bin/nexus came out `-rw-r--r--`, which broke
# an init script that invokes this file directly.
chmod +x "$assembly_dir/bin/nexus" "$assembly_dir/bin/setenv"

log "Build succeeded: $version"
echo "$assembly_dir"

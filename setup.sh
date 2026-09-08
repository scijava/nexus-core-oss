#!/bin/sh
set -e

# Bootstraps Nexus Core OSS on a fresh machine: creates the `nexus`
# service user/data directory, clones the nexus-public source checkout
# that bin/build.sh expects to already exist, and wires up
# /etc/init.d/nexus. Only if Nexus isn't installed yet (no /opt/nexus3)
# does it also run bin/upgrade.sh, once, to build, deploy, and start it
# for the first time.
#
# Deliberately does NOT check for or apply upgrades to an
# already-installed Nexus -- that's what running bin/upgrade.sh directly
# is for (it has its own cheap up-to-date check). This script is meant to
# be safe to re-run routinely without ever rebuilding from source or
# restarting an already-running Nexus.
#
# This also does NOT restore production data (the blob store / database
# under the data directory) -- that has to come from a backup separately.
# It also doesn't redo one-time manual configuration (the secret-
# encryption key, NXRM2-style URLs, users, ...) -- see README.md for both.

dir=$(cd "$(dirname "$0")" && pwd)

test "$(whoami)" = root || { echo "Please run as root." >&2; exit 1; }

nexus_public_dir=${NEXUS_PUBLIC_DIR:-/opt/nexus-public}
nexus_data_dir=${NEXUS_DATA_DIR:-/opt/sonatype-work/nexus3}

echo '--> Ensuring nexus system user/group exists'
id nexus >/dev/null 2>&1 || \
  adduser \
    --home "$nexus_data_dir" --no-create-home --system --group \
    --disabled-password --disabled-login nexus

echo '--> Ensuring data directory exists and is owned by nexus'
mkdir -p "$nexus_data_dir"
chown -R nexus: "$nexus_data_dir"

echo '--> Ensuring nexus-public source checkout exists'
test -d "$nexus_public_dir/.git" || \
  git clone https://github.com/sonatype/nexus-public "$nexus_public_dir"

echo '--> Wiring up /etc/init.d/nexus'
ln -sf "$dir/init.d/nexus" /etc/init.d/nexus

if [ -e /opt/nexus3 ]; then
  echo '--> /opt/nexus3 already exists -- skipping first-install build'
  echo '    (run bin/upgrade.sh directly to check for/apply upgrades)'
else
  echo '--> Building and starting Nexus for the first time'
  NEXUS_PUBLIC_DIR="$nexus_public_dir" "$dir/bin/upgrade.sh"

  echo
  echo '--> Complete. Nexus is running, but empty. Remaining manual steps (see README.md):'
  echo '    - Restore production data from backup, if desired'
  echo '    - Configure the secret-encryption key, NXRM2-style URLs, and other settings'
fi

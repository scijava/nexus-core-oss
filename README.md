# nexus-core-oss

Build, deploy, and run [Nexus Repository Core OSS](https://github.com/sonatype/nexus-public) from source on Linux, painlessly.

Sonatype's official binary distributions of Nexus Repository OSS have been discontinued / are feature-crippled compared to what the `nexus-public` source actually supports. This project builds Core OSS directly from the public `nexus-public` export and deploys it using the same "unix archive" layout convention as Sonatype's official distributions, so nothing downstream needs to know or care that it wasn't built by Sonatype.

Every script here is heavily commented with the specific build/runtime quirks it works around and when/how they were confirmed — read the scripts themselves for details beyond this overview.

## Requirements

- Debian/Ubuntu-family Linux with `systemd` (the init script uses `systemd-run` for process isolation and `adduser`/`pgrep` in the Debian style). Adapting to other init systems or distros should be straightforward — the actual build (`bin/build.sh`) has no such dependency.
- `git`, `curl`, `python3` on `PATH`.
- Root access for install/upgrade/service-management steps. `bin/build.sh` itself and `bin/upgrade.sh --dry-run` need no privileges.

`bin/build.sh` bootstraps its own JDK 25, Maven 3.9, and Node.js/corepack into hidden directories alongside the source checkout — it does not require (or touch) any JDK/Maven/Node already on your system.

## Quickstart

On a fresh machine, as root:

```sh
git clone https://github.com/scijava/nexus-core-oss /opt/nexus-core-oss
/opt/nexus-core-oss/setup.sh
```

This creates the `nexus` service user and data directory, clones `nexus-public` to `/opt/nexus-public`, symlinks `init.d/nexus` to `/etc/init.d/nexus`, and — since `/opt/nexus3` doesn't exist yet — builds the latest release and starts it.

Nexus is now running, but empty and unconfigured. See [Post-install configuration](#post-install-configuration) below.

## Layout

The live layout follows Sonatype's standard "Unix archive" pattern:

- `/opt/nexus3` is a symlink to the current versioned install (e.g. `/opt/nexus-core-3.96.0-09`), containing `bin/`, `etc/`, `deploy/`.
- The data directory (`karaf.data`) is `/opt/sonatype-work/nexus3` by default (override with `NEXUS_DATA_DIR`).
- The service runs as the `nexus` system user by default.

## Building and upgrading

`bin/upgrade.sh` first checks the latest `release-*` tag (`bin/latest-tag.sh`) against what's currently deployed, and exits immediately if they already match. Only when there's an actual new release does it build it (`bin/build.sh`), stage it at `/opt/nexus-core-<version>`, repoint the `/opt/nexus3` symlink, and restart the service — so rollback is just repointing the symlink back to the previous version and restarting.

Run `bin/upgrade.sh --dry-run` to build and report what would happen without touching anything live (a no-op if already current). This is safe to run as an unprivileged user and safe to run routinely (e.g. from cron) — it costs nothing when already up to date.

To just build without deploying anything (e.g. to test the recipe still works against a new release), run `bin/build.sh` directly; it prints the resulting assembly directory on stdout.

## Service management

`init.d/nexus` implements its own start/stop/status logic rather than trusting Nexus Core OSS's own launcher (which has no real service-control support beyond running in the foreground — see the script's comments) or a pidfile. Ubuntu's systemd compatibility generator means `systemctl start|stop|status nexus` also works once the symlink is in place, but there is no native `nexus.service` unit and thus no restart-on-crash policy.

**Always go through `/etc/init.d/nexus`** (or `bin/restart.sh`, suitable for a cron-driven periodic restart) — never invoke `/opt/nexus3/bin/nexus start`/`stop` directly. An overlapping start can leave two Nexus processes fighting over the same embedded database and blob store. After starting or stopping, verify actual process state with `pgrep -af nexus-repository` (exactly one process after start, none after stop).

### Configuration

Machine-specific settings (JDK location, heap size, install paths) belong in `/etc/default/nexus`, sourced by `init.d/nexus` if present — never edit `init.d/nexus` directly, since `setup.sh` re-symlinks it from this checkout on every run. Recognized variables, all optional:

| Variable | Default | Purpose |
| --- | --- | --- |
| `NEXUS_HOME` | `/opt/nexus3` | Path to the active install (the symlink `bin/upgrade.sh` repoints) |
| `NEXUS_DATA_DIR` | `/opt/sonatype-work/nexus3` | Data directory / `karaf.data` |
| `NEXUS_USER` | `nexus` | System user the service runs as |
| `NEXUS_JAVA_HOME` | unset (trust `PATH`) | JDK used to run Nexus. Set this if your system's default `java` is older than the current release requires — see `init.d/nexus` for why the bundled launcher can't detect a suitable JDK on its own the way Sonatype's official distributions do |
| `NEXUS_JAVA_MIN_MEM`, `NEXUS_JAVA_MAX_MEM`, `NEXUS_DIRECT_MAX_MEM` | `2703m` each | JVM heap/direct-memory sizing — raise these on boxes with more RAM to spare |

Example `/etc/default/nexus`:

```sh
NEXUS_JAVA_HOME=/usr/lib/jvm/java-25-openjdk-amd64
NEXUS_JAVA_MIN_MEM=8192m
NEXUS_JAVA_MAX_MEM=8192m
NEXUS_DIRECT_MAX_MEM=8192m
```

`bin/build.sh` and `bin/upgrade.sh` also honor `NEXUS_PUBLIC_DIR` (default `/opt/nexus-public`) to relocate the source checkout.

## Post-install configuration

For a healthy repository, configure the following after a fresh installation, from the web UI under **Settings → System → Capabilities**:

- Add **NXRM2 style URLs**, to support queries to both `/repositories` and `/content/repositories`. Failing to do so results in missed queries and a high volume of 404 spam.
- Also consider setting: Base URL, Audit, Outreach notifications, Default Role.

### Custom secret-encryption key

Nexus warns under **Status → Support** when stored secrets use its default encryption key. Configure a unique key before adding credentials, tokens, or other sensitive configuration.

> **Important:** Once Nexus uses this key, the key file is required to decrypt stored secrets. Back it up securely, do not commit it to version control, and do not lose it.

1. Stop Nexus (`/etc/init.d/nexus stop`; confirm no process remains with `pgrep -af nexus-repository`).
2. Generate the key file (adjust `$NEXUS_DATA_DIR` if you overrode it):
   ```sh
   install -d -o nexus -g nexus -m 700 /opt/sonatype-work/nexus3/etc/secrets
   key=$(openssl rand -base64 32)
   install -o nexus -g nexus -m 600 /dev/null /opt/sonatype-work/nexus3/etc/secrets/nexus-secrets.json
   printf '{\n  "active": "master",\n  "keys": [\n    {\n      "id": "master",\n      "key": "%s"\n    }\n  ]\n}\n' "$key" \
     > /opt/sonatype-work/nexus3/etc/secrets/nexus-secrets.json
   unset key
   ```
3. Point Nexus at it:
   ```sh
   printf '\nnexus.secrets.file=/opt/sonatype-work/nexus3/etc/secrets/nexus-secrets.json\n' \
     >> /opt/sonatype-work/nexus3/etc/nexus.properties
   ```
4. Start Nexus (`/etc/init.d/nexus start`) and confirm under **Status → Support → System Status Checks** that **Default Secret Encryption Key** reports healthy.

Include the `nexus-secrets.json` file in secure backups, mode `0600`. A restored Nexus database containing encrypted secrets requires this same key file.

## License

Public domain — see [LICENSE](LICENSE) (Unlicense).

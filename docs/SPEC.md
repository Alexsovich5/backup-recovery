# backup-recovery: Specification

Rebuild target: a small, working Bacula 5.2 backup and recovery setup built the way it would have been in late 2013 / January 2014 on Debian 7 "wheezy". It ships Bacula configuration, Bash tooling around `bconsole`, and a Python 2.7 catalog report, and runs as a self-contained Docker stack.

The original README is used only for the technical concept (Bacula, shell scripting, MySQL, Python 2.7, rsync; scheduling, encryption, recovery, verification, disaster recovery). Its role, organisation, dates, "business impact" figures and status badge are not carried over.

---

## 1. Problem

A small Linux estate needs nightly backups that:

- run on a schedule without anyone touching them,
- are encrypted at the client before data leaves the host,
- can be restored with one command, without an operator working through the interactive `bconsole` restore dialogue,
- are checked regularly, so you learn a backup is bad before you need it,
- and survive loss of the backup server itself, which means a copy of the volumes, bootstrap files and catalog is kept on a second host.

Bacula provides the engine (Director, Storage Daemon, File Daemon, MySQL catalog). This project supplies the configuration and the operational glue around it: scripts, a report and tests.

## 2. In scope

1. **Bacula configuration**: Director, Storage Daemon, File Daemon and bconsole configs for one director/storage host (which also runs its own File Daemon, `backup-fd`) and one client (`server01`). Configs are rendered from templates, with passwords taken from an env file. `bacula-sd`, `bacula-fd` and `bconsole` configs pass `-t` in `make lint`. `bacula-dir -t` needs a live catalog connection in 5.2.6 (it calls `check_catalog()` before honouring `-t`), so it is checked in the integration suite against the running catalog.
2. **MySQL catalog**: a MySQL 5.5 catalog created with Bacula's own `make_mysql_tables` script, plus Full/Differential/Incremental pools with separate retention.
3. **Backup scheduler**:
   - One scheduled job, `server01-backup`, with `Full Backup Pool`/`Differential Backup Pool`/`Incremental Backup Pool` directives and Schedule `WeeklyCycle`: Full on the 1st Sunday, Differential on the 2nd to 5th Sunday, Incremental Monday to Saturday, all at 23:05. Only this job and `BackupCatalog` carry a `Schedule`, so exactly one client backup runs per night.
   - `scripts/backup.sh <client> <full|incremental|differential>` for on-demand runs of the unscheduled level-named jobs. It waits for the job to finish and exits non-zero unless the job ends in status `T`.
4. **Encryption module**:
   - File Daemon PKI data encryption and signing (Bacula `PKI Encryption`/`PKI Signatures`) with a per-client keypair and a separate master recovery key.
   - `scripts/gen-keys.sh` generates the keys with OpenSSL.
5. **Recovery interface**: `scripts/restore.sh`, a non-interactive restore CLI. It restores a client's files, the full tree or selected paths, from the most recent backup or from a point in time, into a target directory, optionally on a different File Daemon (`restoreclient=`).
6. **Verification system**:
   - A Bacula Verify job at level `VolumeToCatalog`. The scheduled `server01-backup` job queues it through a Director-side `RunScript` that runs `scripts/queue-verify.sh` (5.2.6 refuses a `run` console command inside a RunScript: "Can't use run command in a runscript"); `backup.sh` queues it for on-demand runs. There is exactly one trigger per backup.
   - `scripts/restore-test.sh`, an automated restore test. It restores into a scratch directory and compares MD5 checksums against a manifest taken at backup time.
   - `bin/catalog_report.py` (Python 2.7) queries the catalog for failed backup/verify jobs and for clients with no successful backup inside a threshold. It uses a Nagios-style exit code (0/1/2/3).
7. **Notifications**: Bacula `Messages` resources and `backup.sh` send job reports by mail through `bsmtp`, and `bsmtp` delivers to a local SMTP sink.
8. **Disaster recovery**:
   - A `BackupCatalog` job (client `backup-fd`, the FD on the director host) dumps the catalog (`make_catalog_backup.pl`) and backs up the dump, unencrypted, with its own bootstrap file.
   - Its `RunAfterJob` step runs `scripts/offsite-sync.sh`, which uses rsync to copy volumes, bootstrap (`.bsr`) files and the catalog dump to an offsite host.
   - `scripts/dr-drill.sh` proves that the offsite copy plus the master recovery key can restore on their own:
     1. `bextract -b BackupCatalog.bsr` recovers `bacula.sql` from the offsite volumes without a Director. This works because the catalog FileSet is unencrypted and uncompressed. The result is compared with the rsync'd dump.
     2. The dump is loaded into a scratch database `bacula_drill`, and the drill asserts that it holds successful `server01-fd` backups.
     3. A scratch Director and SD (`drill-dir`/`drill-sd`, on their own ports and working directory) start in the `drill` service (not the director) on that catalog and a copy of the offsite volumes. The recovery File Daemon `drill-fd` runs on its own host, the `dr-client` service, which is the only place the master private key exists (see §4, "Key separation"). `drill-fd` holds only the master key and cert as its `PKI Keypair`, with `PKI Encryption = yes`. 5.2.6 `bacula-fd` loads the keypair for decryption only when `PKI Encryption` or `PKI Signatures` is on. Signatures made with server01's key take the no-signer path, which logs only a debug message, so restore still proceeds.
     4. The drill restores `server01-fd`'s latest data with `restoreclient=drill-fd` into a fresh directory on the shared `drillrestores` volume, refuses the result if a symlink lies on any manifest path (between the restore directory and the file), and checks it with `md5sum -c` against the manifest.

     `bextract` alone cannot be used for client data: 5.2.6 `bextract` has no decryption support and skips encrypted data streams. Step 3 also proves the master recovery key works.

## 3. Out of scope

| Original README item / implied feature | Reason |
|---|---|
| Tape drives / autochangers (`mtx`, `mt-st`) | No hardware. File-based storage devices stand in for tape. The volume and pool logic is the same. |
| Multiple production clients / Windows clients | One Linux client (`server01`) shows the whole flow. Adding clients is config-only and does not need new code. |
| Graphical "recovery interface" (bat, Bweb, webmin module) | For a solo project a CLI is the realistic recovery interface. A GUI adds nothing that can be tested. |
| "Zero data loss", "4-hour RTO", "significant improvement in operational efficiency" | These are fabricated business metrics, and nothing in this repo measures them. |
| "Automated testing" as a business-impact claim | The real feature is automated restore testing (in scope #6). The claim itself is dropped. |
| TLS between Bacula daemons | Everything runs on one Docker network. FD PKI (#4) encrypts file contents before they leave the client, but not file names, attributes or the daemon control channel. Daemon TLS would protect those, but it doubles the key management for a single-network lab, so it is left out. |
| Real remote DR site / WAN replication | Simulated by an `offsite` container running an rsync daemon (see §8). |
| Real mail server | Simulated by a Python 2.7 `smtpd.DebuggingServer` sink (see §8). |
| systemd service checks (existing `backup.sh` calls `systemctl`) | wheezy uses sysvinit. The check is replaced by probing the Director through `bconsole status dir`. |
| Cron-driven scheduling | Bacula's own scheduler is the period-correct choice. Cron is not needed. |
| `src/`, `docs/`, `tests/` tree from the original README "Project Structure" | The layout follows the real code (see Implementation Plan). Empty placeholder directories are not created. |

## 4. Architecture

```
                         docker compose network "backupnet" (172.44.0.0/25)
 +-------------------+     +-------------------------------+     +----------------------+
 | catalog           |     | director                      |     | server01 (client)    |
 | mysqld 5.5.35     |<----| bacula-dir 5.2.6  :9101       |---->| bacula-fd 5.2.6 :9102|
 | db: bacula        | SQL | bacula-sd  5.2.6  :9103       |     | PKI encrypt + sign   |
 | (+ bacula_drill   |     | bacula-fd  5.2.6  :9102       |<----| /srv/data  (srvdata) |
 |  during DR drill) |     |   = client backup-fd          | data| /restores  (restores)|
 +-------------------+     | bconsole, bats, /src (ro)     |     | /etc/bacula/keys     |
          ^                | /var/lib/bacula/volumes       |     |  (keys: own keypair  |
          |                | /clientdata/server01 (srvdata)|     |   + master.cert)     |
          |                | /restores (restores)          |     +----------------------+
          |                | /var/log/smtp-sink (maillog,ro)          ^ master.cert (masterpub, ro)
          |                | /offsite (offsite,ro)         |     +----------------------+
          |                | NO private keys, no drill     |     | dr-client            |
          |                | password                      |     | profile "drill",     |
          |                +-------------------------------+     | drillnet only        |
          |                                                      | drill-fd :9202       |
          |                                                      | /etc/bacula/keysafe  |
          |                                                      |  (keysafe: master    |
          |                                                      |   keypair, only here)|
          |                                                      +----------------------+
          |  drill (profile "drill", throwaway) is on backupnet and on drillnet
          |  (172.44.0.128/25, internal; only drill and dr-client): drill-dir :9201,
          |  drill-sd :9203, /offsite (ro), /clientdata/server01 (ro), /drill-restores
          |                   |  bsmtp :25          | rsync :873 (RunAfterJob BackupCatalog)
          | catalog_report.py v                     v
          +--------------- +-----------+     +---------------------------+
                           | smtp sink |     | offsite                   |
                           | py2.7 -u  |     | rsyncd, module "bacula"   |
                           | smtpd     |     | /offsite/{volumes,bsr,db} |
                           | (maillog) |     |  (offsite volume)         |
                           +-----------+     +---------------------------+
 tools  (same image, no daemons): runs bats unit tests, python unittest, sd/fd/bconsole -t
```

Named volumes shared between containers give tests one place to observe everything (see §10):

| Volume | Mounted in | Purpose |
|---|---|---|
| `srvdata` | server01 `/srv/data`; director `/clientdata/server01`; drill `/clientdata/server01` read-only | Client data. Manifests are built from the director side (tests) and by the drill service. |
| `restores` | server01 `/restores`; director `/restores` | Restore target on the client, readable by the director at the same path. |
| `keys` | server01 `/etc/bacula/keys` only | server01's own keypair plus the master **certificate**. Generated on first start by `entrypoint-client.sh`; files owned by `bacula`, private files mode 0400. Excluded from `ServerFileSet`, so no restore ever writes a private key. |
| `keysafe` | dr-client `/etc/bacula/keysafe` only | The master recovery keypair (`master.key`, `master.cert`, `master.pem`), generated on first start by `entrypoint-drclient.sh`. Stands in for the offline key safe; never mounted into the director or server01. |
| `masterpub` | dr-client `/masterpub`; server01 same path, read-only | `master.cert` (public) published by dr-client for server01's `PKI Master Key`. |
| `drillrestores` | dr-client and drill `/drill-restores` | Restore target of the DR drill on drill-fd, checked from the drill service. |
| `maillog` | smtp `/var/log/smtp-sink`; director same path, read-only | SMTP sink log. |
| `offsite` | offsite `/offsite`; director and drill `/offsite` read-only | Offsite copy. |

Each service bind-mounts, read-only, only the repo directories it uses under `/src` (for example `docker/`, `config/`, `scripts/`; the director also `bin/` and `tests/integration/`, the drill service `tests/drill/`). Only the throwaway `tools` container mounts the whole repo read-write, because `make lint` writes `build/`; no service sees `build/`, and `tools` hides `secrets/` under a tmpfs. All Bacula `Run*` script paths point at `/src/scripts` through `@SCRIPT_DIR@`. The image does not contain the scripts.

**Key separation.** Client-side PKI exists so that the Director, the Storage Daemon and anyone holding the volumes (including the offsite copy) cannot read client data. The director container (Director, Storage Daemon, `backup-fd`) therefore holds no private key: server01 has only its own keypair and the master certificate; the master private key exists only in the `keysafe` volume of `dr-client`, the recovery host used by the DR drill.

**Recovery host isolation.** `dr-client` and `drill` are behind the compose profile `drill`, so `docker compose up -d` does not start them and the master key is not loaded in a running process between drills. `make keys` runs `dr-client` once with the argument `init` (create the keypair, publish `master.cert`, exit); `make drill` starts `dr-client`, runs the `drill` service and stops `dr-client` again. `dr-client` is attached to `drillnet` only, an internal network with no route to the catalog, the Director or the internet; the `drill` service is the only member of both `backupnet` and `drillnet`. The two networks are halves of the subnet reserved for the stack, 172.44.0.0/25 and 172.44.0.128/25. Before it touches the key directory, `entrypoint-drclient.sh` (and `entrypoint-client.sh` for its own) runs `keydir_check` (`scripts/lib/keys.sh`): the directory and every key file must be real, not symlinks, and owned by root or `bacula`, and the directory must not be writable by group or others; otherwise the service refuses to start before any chown, chmod or copy.

**Secrets per service.** Passwords are kept in `secrets/passwords.env` (untracked, created by `make env` from `config/passwords.env.example`). `scripts/split-secrets.sh` writes one 0600 file per service under `secrets/`, each compose service gets only its own as a compose secret (`/run/secrets/<service>`), and the entrypoints source it. Nothing secret goes through `environment:` or `env_file:`, no service mounts `./secrets`, and `scripts/check-container-env.sh` checks `docker inspect` output of the running containers. The files hold: `catalog` DB and drill-account passwords; `director` Director, FD, SD, DB and offsite passwords; `server01` the FD password; `offsite` the rsync password; `dr-client` `DRFD_PASSWORD`; `drill` `DRFD_PASSWORD` and the password of MySQL account `drill`, which has rights on `bacula_drill` only (no access to the live catalog). The director therefore never holds the recovery daemon's password. `config/bacula.env` keeps only host names and paths.

Data flow for a nightly backup:
1. The Director's scheduler starts `server01-backup` at the level set by the `WeeklyCycle` Run line. `backup.sh` starts a level-named job such as `server01-full` instead.
2. The Director asks the FD on `server01` for data. For each file the FD computes an MD5 signature, compresses the file (except files matching `*secret.txt`, see §5.2), then signs and encrypts it with the client keypair and master key, and streams it to the SD.
3. The SD writes to the file volume in the right pool. The Director writes file and job records to the MySQL catalog and writes `/var/lib/bacula/server01-fd.bsr`.
4. After a successful `server01-backup`, its Director-side `RunScript` (`Command = "@SCRIPT_DIR@/queue-verify.sh %c"`, which sends `run job=Verify-server01 yes` through its own bconsole session) queues one VolumeToCatalog verify. For on-demand runs, `backup.sh` queues the verify itself.
5. Every night after the client job, `BackupCatalog` (client `backup-fd`) dumps MySQL, backs up the dump, and writes `/var/lib/bacula/BackupCatalog.bsr`. Then `offsite-sync.sh` copies volumes, `.bsr` files and the dump to `offsite::bacula`.
6. Messages go to `/var/log/bacula/bacula.log` and through `bsmtp` to the SMTP sink.

Recovery flow: `restore.sh` builds a non-interactive `restore ... select all done yes` bconsole command, waits for the job, and reports the result. The DR flow uses only `/offsite` and the master key on `dr-client` (§2 #8). It runs a scratch Director/SD on ports 9201/9203 with their own working directory in the `drill` service plus `drill-fd` (port 9202) on `dr-client`, so the live daemons are not involved.

A single image (`backup-recovery:wheezy`) is built once. Every service runs it with a different entrypoint. `entrypoint-director.sh` renders the configs into `/etc/bacula/`, which is where the Debian `make_catalog_backup.pl` and `dbcheck` expect them.

## 5. Data model & interfaces

### 5.1 Config templates

`config/*.conf` are templates containing `@NAME@` placeholders. `scripts/render-config.sh <template> <out>` replaces each `@NAME@` with the value of environment variable `NAME`. It fails (exit 3) if a variable is unset or if any `@...@` is left afterwards. The Makefile creates `config/bacula.env` from `config/bacula.env.example` (host names and paths) and `secrets/passwords.env` from `config/passwords.env.example` (passwords) when they are missing. Entrypoints source `config/bacula.env` and their own secret file from `/run/secrets`, then apply per-service overrides.

| Placeholder | Source (`config/bacula.env` from `config/bacula.env.example`; passwords from the service's secret file, see §4) |
|---|---|
| `@DIR_PASSWORD@` | Director / bconsole password |
| `@FD_PASSWORD@` | Director ↔ FD password |
| `@SD_PASSWORD@` | Director ↔ SD password |
| `@DB_PASSWORD@` | MySQL `bacula` user password |
| `@DIR_HOST@`, `@SD_HOST@`, `@DB_HOST@`, `@FD_HOST@`, `@SMTP_HOST@` | compose hostnames |
| `@DRILL_SD_HOST@`, `@DB_USER@` | Drill Director config only: host of `drill-sd` as `drill-fd` reaches it (the `drill` service) and the catalog account (`drill`, set by the service; `bacula` by default) |
| `@ADMIN_EMAIL@` | notification recipient (default `backup-admin@localhost`) |
| `@KEY_DIR@` | PKI key directory. The example uses `/src/build/keys`, which `make lint` fills. `entrypoint-client.sh` overrides it to `/etc/bacula/keys`, `entrypoint-drclient.sh` to `/etc/bacula/keysafe`. |
| `@SCRIPT_DIR@` | Directory of the Run*Job scripts (`/src/scripts`) |
| `@DRILL_DIR@`, `@DRILL_PASSWORD@`, `@DRILL_RESTORE_DIR@` | Drill configs only (`config/drill/`): the drill's scratch directory, a per-run random password for drill-dir/drill-sd/bconsole and the restore directory on drill-fd, set by `dr-drill.sh` (lint uses `/src/build/drill` and fixed values). The drill configs also use `@DB_HOST@`, `@DB_USER@`, `@DB_PASSWORD@` and `@DRILL_SD_HOST@`. |
| `@DRFD_HOST@`, `@DRFD_PASSWORD@` | Host of the recovery File Daemon `drill-fd` (`dr-client`) and the password drill-dir uses for it. |
| `OFFSITE_PASSWORD` | Password of rsync daemon user `bacula` on the offsite host (not a template placeholder; written into root-only files by `entrypoint-offsite.sh` and `entrypoint-director.sh`). |
| `DRILL_DB_PASSWORD` | Password of MySQL account `drill` (rights on `bacula_drill` only). The `drill` service receives it as `DB_PASSWORD`. |

Files: `bacula-dir.conf`, `bacula-sd.conf`, `bacula-fd.conf` (server01, PKI), `bacula-fd-director.conf` (`backup-fd`, no PKI), `bconsole.conf`, `rsyncd.conf`, `drill/bacula-{dir,sd,fd}-drill.conf`, `backup.conf.example` (sourced by the scripts).

### 5.2 Bacula resources (names are an interface: scripts depend on them)

| Resource | Name(s) |
|---|---|
| Director | `backup-dir` |
| Clients | `server01-fd` (PKI encryption on), `backup-fd` (FD on the director host, no PKI; runs `BackupCatalog`) |
| Jobs (scheduled) | `server01-backup` (Schedule `WeeklyCycle`; Full/Differential/Incremental Backup Pool; `RunScript { RunsWhen = After; RunsOnFailure = No; RunsOnClient = No; Command = "@SCRIPT_DIR@/queue-verify.sh %c" }`), `BackupCatalog` (Client `backup-fd`, FileSet `CatalogFileSet`, Pool `Default`, Schedule `WeeklyCycleAfterBackup`, `Write Bootstrap = /var/lib/bacula/BackupCatalog.bsr`) |
| Jobs (on demand, no Schedule) | `server01-full`, `server01-incremental`, `server01-differential`, `Verify-server01` (`Pool = Default`), `RestoreFiles` |
| Jobs (test-only, no Schedule) | `server01-fail` (`ClientRunBeforeJob = /bin/false`, fails at once with status `f`), `plaintext-control` (Client `backup-fd`, FileSet `ControlFileSet`, Pool `Default`; the encryption control case) |
| JobDefs | `DefaultJob` (Client `server01-fd`, FileSet `ServerFileSet`, Storage `File`, Messages `Standard`, Pool `Default`, `Write Bootstrap = /var/lib/bacula/%c.bsr`; **no Schedule, no Run After Job**) |
| FileSet | `ServerFileSet` (`/srv/data`, `/etc`; first Options block `wildfile = "*secret.txt"`, `signature = MD5`, no compression; second Options block `signature = MD5`, `compression = GZIP`; `Exclude` of the runtime-mounted `/etc/hostname`, `/etc/hosts`, `/etc/resolv.conf`), `CatalogFileSet` (`/var/lib/bacula/bacula.sql`; MD5, no compression), `ControlFileSet` (`/src/tests/fixtures/data/secret.txt`; no compression) |
| Schedule | `WeeklyCycle` (Full 1st sun / Diff 2nd-5th sun / Incr mon-sat, 23:05), `WeeklyCycleAfterBackup` (Full sun-sat, 23:30) |
| Pools | `FullPool` (365 d, `Label Format = "Full-"`), `DifferentialPool` (90 d, `"Diff-"`), `IncrementalPool` (30 d, `"Incr-"`), `Default` (`"Default-"`) |
| Storage | `File` → SD device `FileStorage` at `/var/lib/bacula/volumes`, `Media Type = File`, `LabelMedia = yes` |
| Messages | `Standard`, `Daemon` |
| Drill (`config/drill/`) | `drill-dir` (127.0.0.1:9201, catalog `bacula_drill`), `drill-sd` (:9203, Storage `File` at `@DRILL_SD_HOST@`, device over the scratch copy of the offsite volumes), `drill-fd` (on `dr-client` :9202, `PKI Encryption = yes`, `PKI Keypair = @KEY_DIR@/master.pem`), Clients `server01-fd` (never contacted) and `drill-fd` |
| FileSet (test-only) | `KeyDirFileSet` (`/etc/bacula/keys`), used only with `estimate ... listing` to see which key files server01 holds; `ServerFileSet` excludes `/etc/bacula/keys` |

### 5.3 CLIs

```
scripts/backup.sh <client> <full|incremental|differential> [--no-verify]
    runs <client>-<level>, then (unless --no-verify) run job=Verify-<client>
    <client> must be a plain Bacula name (letters, digits, . _ : -)
    exit 0 job T (and verify T); 1 job failed; 2 usage; 3 director unreachable; 4 verify failed

scripts/restore.sh --client <client> [--where DIR] [--before 'YYYY-MM-DD HH:MM:SS']
                   [--jobid N] [--file PATH ...] [--restore-client FD] [--dry-run]
    default: newest backup, all files, where=/tmp/bacula-restores, restoreclient=<client>-fd
    --dry-run prints the bconsole command only
    client names must be plain Bacula names; --where must be absolute; no
    value may contain a double quote or control character (exit 2), so no
    argument can add a second bconsole command
    exit 0 restore T; 1 restore failed; 2 usage; 3 director unreachable

scripts/queue-verify.sh <client>
    queues run job=Verify-<client> (a trailing -fd is dropped) and returns at once
    exit 0 queued; 1 not queued; 2 usage

scripts/make-manifest.sh <dir> <out>
    md5sum of every file under <dir>, paths relative to <dir>, sorted

scripts/restore-test.sh --client <client> --manifest FILE [--where DIR] [--root /srv/data]
    restores (restore.sh) into DIR on the client, then md5sum -c against the manifest
    from DIR/<root>. DIR must be visible locally at the same path (the shared
    /restores volume in the stack). A manifest line with an absolute path, a
    '..' component or a malformed/escaped entry is refused (exit 2) before
    anything is deleted or restored (check_manifest in lib/common.sh). Once a
    restore tree exists, check_manifest FILE ROOT BASE also refuses (exit 1) a symlink
    on any manifest path below BASE, before files are deleted and before md5sum -c.
    exit 0 all match; 1 mismatch/missing; 2 usage

scripts/gen-keys.sh [--client] <outdir> <client-name> | --master <outdir>
    --client: <client>.key, <client>.cert, <client>.pem (key+cert) only
    --master: master.key, master.cert, master.pem (key+cert) only
    no option: both sets (make lint)
    refuses to overwrite existing keys (exit 1); usage exit 2

scripts/offsite-sync.sh [--dest rsync://bacula@offsite/bacula]
    rsync -a --password-file=$OFFSITE_PASSWORD_FILE (default /etc/bacula/offsite.passwd)
    volumes/ -> <dest>/volumes/, *.bsr -> <dest>/bsr/, bacula.sql -> <dest>/db/
    exit = rsync exit; 2 usage or unreadable password file

scripts/drill-run.sh [dr-drill.sh args]
    drill service entry point: waits for drill-fd on $DRFD_HOST:9202, writes a manifest
    of /clientdata/server01 (read-only), runs dr-drill.sh --offsite /offsite with it

scripts/dr-drill.sh --offsite DIR --manifest FILE [--restore-dir /drill-restores]
                    [--db-host H] [--root /srv/data]
    0 manifest checked as in restore-test.sh (exit 2 on unsafe paths)
    1 bextract -b DIR/bsr/BackupCatalog.bsr -> bacula.sql, cmp with DIR/db/bacula.sql
    2 load bacula.sql into bacula_drill, assert >=1 Type=B JobStatus=T job for server01-fd
    3 start drill-dir/-sd here (on $DRILL_SD_HOST); drill-fd (master key) already runs on $DRFD_HOST
    4 restore client=server01-fd restoreclient=drill-fd where=<restore-dir>/drill.XXXXXX ...;
      wait; refuse symlinks on manifest paths; md5sum -c there
    always (trap): stop drill daemons, DROP DATABASE bacula_drill, remove scratch and
    restore dirs
    prints "catalog jobs: N", "files verified: N"; exit 0 pass; 1 fail; 2 usage

scripts/render-config.sh <template> <output>

bin/catalog_report.py [--host H] [--db bacula] [--user U] [--password-file F]
                      [--max-age-hours 26] [--since-hours 24] [--format text|nagios]
    considers Type 'B' and 'V' jobs only (restores are not counted)
    failed = JobStatus E, e, f or D (verify differences)
    exit 0 OK; 1 WARNING (a client's last good backup older than max-age);
         2 CRITICAL (failed jobs in window); 3 UNKNOWN (catalog unreachable,
         or no clients in the catalog); error text never contains the password
```

### 5.4 Shared shell library: `scripts/lib/common.sh`

`log_message MSG`, `die CODE MSG`, `bconsole_cmd "<commands>"` (pipes into `bconsole -c $BCONSOLE_CONF`), `parse_jobid` (reads stdin, extracts `JobId=N` from "Job queued. JobId=N"), `wait_job JOBID` (terminal statuses T W E e f A D, matched independently of `IFS`), `job_status JOBID` (one-letter JobStatus from `list jobid=N`), `director_up`, `bacula_name_ok NAME`, `bconsole_arg_ok VALUE` and `check_manifest FILE` (input validation, see §5.3). All helpers read stdin or arguments and never exit on their own, so they can be unit tested against fixture text.

### 5.5 Catalog tables used by the report

These are the stock Bacula 5.2 schema tables `Job(JobId, Name, ClientId, Level, JobStatus, Type, StartTime, EndTime, JobFiles, JobBytes)` and `Client(ClientId, Name)`. The report queries them read-only and adds no schema of its own.

### 5.6 Restore manifest format

This is plain `md5sum` output (`<md5>  <relative path>`), generated by `scripts/make-manifest.sh <dir> <out>`. In the stack it runs in the director container over `/clientdata/server01`, which is the same `srvdata` volume that server01 backs up as `/srv/data`. The manifest is written to the test's temp directory and passed to `restore-test.sh`/`dr-drill.sh` by path.

## 6. Stack & pinned versions

The base image is Debian 7 wheezy. Packages are installed with **exact version pins**, only from the Debian archive as it stood on 2014-01-31, fetched over HTTPS and verified against the archive signatures (see §7). Packages marked *(security)* exist only in the `debian-security` snapshot.

| Component | Version | Upstream release date | Why it was the popular choice then |
|---|---|---|---|
| Bacula (dir/sd/fd/console, MySQL backend) | 5.2.6 (Debian `5.2.6+dfsg-9`) | 2012-02-21 (5.2.6). Latest upstream 5.2.x in period was 5.2.13, 2013-02-19 | The dominant open-source network backup system on Linux in 2013. 5.2.6 is what wheezy shipped, and most admins ran the distro package. Bareos had only just forked (12.4, 2013) and was not yet widespread. |
| MySQL server/client *(security)* | 5.5.35 (Debian `5.5.35+dfsg-0+wheezy1`) | 2013-12-03 | MySQL was Bacula's most-used catalog backend, and 5.5 was the wheezy default. |
| Bash | 4.2 (wheezy `bash` package; the base image's build is kept) | 2011-02-13 | Standard shell on wheezy. |
| Python | 2.7.3 (Debian `2.7.3-6`) | 2012-04-09 | The wheezy default Python. Python 3 was not yet used for ops scripting. |
| MySQL-python (MySQLdb) | 1.2.3 (Debian `python-mysqldb 1.2.3-2`) | 2010-07-22 (verified with check_period.py) | The standard MySQL driver for Python 2. |
| mock | 0.8.0 (Debian `python-mock 0.8.0-3`) | 2012-02-13 (verified) | The de facto mocking library for Python 2 unittest. |
| nose | 1.1.2 (Debian `python-nose 1.1.2-3`) | 2011-07-31 (verified) | The most common Python 2 test runner. |
| OpenSSL *(security)* | 1.0.1e (Debian `1.0.1e-2+deb7u3`) | 2013-02-11 | Used by Bacula PKI and `gen-keys.sh`. |
| rsync | 3.0.9 (Debian `3.0.9-4`) | 2011-09-23 | Standard tool for copying to an offsite host. |
| GNU make | 3.81 (Debian `3.81-8.2`) | 2006-04-01 | wheezy default. |
| Bats (Bash Automated Testing System) | 0.3.1 (tag `v0.3.1`, commit `2e24778`) | 2013-10-28 (tag commit date, verified via GitHub API) | A new (Oct 2013) TAP-producing Bash test framework, chosen over the more established shUnit2 for its simpler syntax. Its TAP output fits CI. |

Pin list of the packages named on purpose. `docker/apt/packages.lock` holds these plus every dependency they pull in (67 packages), each with its exact version and suite. There are no globs.

| Package(s) | Version | Suite |
|---|---|---|
| `bacula-common`, `bacula-common-mysql`, `bacula-director-common`, `bacula-director-mysql`, `bacula-sd`, `bacula-sd-mysql`, `bacula-fd`, `bacula-console` | `5.2.6+dfsg-9` | wheezy |
| `mysql-server`, `mysql-server-5.5`, `mysql-server-core-5.5`, `mysql-client-5.5`, `mysql-common`, `libmysqlclient18` | `5.5.35+dfsg-0+wheezy1` | wheezy/updates *(security)* |
| `openssl`, `libssl1.0.0` | `1.0.1e-2+deb7u3` | wheezy/updates *(security)* |
| `python2.7`, `python2.7-minimal`, `libpython2.7` | `2.7.3-6` | wheezy |
| `python-mysqldb` | `1.2.3-2` | wheezy |
| `python-mock` | `0.8.0-3` | wheezy |
| `python-nose` | `1.1.2-3` | wheezy |
| `rsync` | `3.0.9-4` | wheezy |
| `make` | `3.81-8.2` | wheezy |

All versions above were checked against the 20140131T000000Z `Packages` indexes of both snapshot suites.

`check_period.py` verification: a manifest with `MySQL-python==1.2.3`, `mock==0.8.0` and `nose==1.1.2` passed (exit 0, 3 checked, 0 problems). The repo keeps these pins in `requirements.txt` for documentation and re-checking. They are installed from Debian packages, not pip, because wheezy's pip 1.1 cannot reach today's PyPI.

Development harness (not part of the period stack): Docker and `docker compose` orchestrate the containers. Docker 0.7 and fig 0.1 existed in the period, but the harness uses current Docker for practicality.

## 7. Docker images

| Image | Tag | Verified | Notes |
|---|---|---|---|
| `debian` | `wheezy` (pinned by digest) | Hub API HTTP 200 (re-checked; last_updated 2019-03-05, amd64 present) | Base of the runtime image. It resolves to final wheezy 7.11. Tags from the period (`7.3`, `7.4`) exist on Hub (HTTP 200) but use schema-v1 manifests that current Docker refuses to pull ("unsupported manifest media type"). `wheezy` is therefore the nearest pullable period tag. Period accuracy for the software that matters comes from exact version pins against the 2014-01-31 snapshot. |
| `debian` | `bookworm-slim` (pinned by digest) | build stage only | The `fetch` stage: current curl, CA certificates, `gpgv` and `debian-archive-keyring` (including the removed, expired wheezy keys) to download and verify the packages. Nothing from it is installed into the runtime image except the verified `.deb` files and the Bats tree. |
| `mysql` | *(not used)* | `5.5` HTTP 200, `5.5.35` HTTP 404 | The catalog runs MySQL 5.5.35 from the wheezy snapshot in the same image instead, so the version matches the period exactly. |

Package retrieval (two-stage Dockerfile, changed in T14):
- **`fetch` stage** (`debian:bookworm-slim`): `docker/apt/fetch-debs.sh docker/apt/sources.conf docker/apt/packages.lock /debs`. For each suite in `sources.conf` (both `https://snapshot.debian.org/archive/{debian,debian-security}/20140131T000000Z`, dists `wheezy` and `wheezy/updates`) it downloads `Release` and `Release.gpg` over HTTPS only (`curl --proto '=https' --proto-redir '=https'`), verifies the signature with `gpgv` against `debian-archive-keyring.gpg` plus `debian-archive-removed-keys.gpg` (a `VALIDSIG` is required; the wheezy keys have expired since, which does not invalidate a signature made in 2013/2014), checks the `Codename`, checks `main/binary-amd64/Packages.gz` against its SHA256 in `Release`, and checks every `.deb` named in the lock against its SHA256 in `Packages`. Any mismatch fails the build.
- The lock (`source package version` per line) is the exact package set apt resolved for the §6 pins on top of `debian:wheezy` (67 packages, including the downgrades of the base image's newer `libssl1.0.0` and `perl-base` to the snapshot versions). No `archive.debian.org` or `deb.debian.org` package is used; those carry post-2014 wheezy builds.
- **Runtime stage** (`debian:wheezy`): all apt sources are removed; `docker/apt/install-debs.sh` installs the verified `.deb` files with `dpkg -i` (packages that others pre-depend on go in an earlier pass). There is no `--force-yes`, `--allow-unauthenticated`, `[trusted=yes]`, `AllowUnauthenticated` or `http://` source anywhere; `tests/unit/apt-sources.bats` fails if one is reintroduced in any Dockerfile or apt file, and checks that the built image has no apt sources. `tests/unit/00-toolchain.bats` still checks every pinned version with `dpkg-query`.
- dbconfig-common answers are preseeded (`bacula-director-mysql/dbconfig-install boolean false`), and the catalog is created by our entrypoint; the package's own attempt fails harmlessly at build time because no MySQL server runs then.
- Bats 0.3.1 is downloaded over HTTPS in the `fetch` stage from the GitHub tag tarball and checked against a SHA-256 recorded in the Dockerfile.

## 8. Simulated / mocked integrations

| Real-world system | Replacement | Where |
|---|---|---|
| Remote DR site / offsite server | `offsite` container running `rsync --daemon` (rsync 3.0.9) with module `bacula`, login `bacula` required | `docker-compose.yml`, `config/rsyncd.conf` |
| Recovery Director/SD at the DR site | Scratch `drill-dir`/`drill-sd` started by `dr-drill.sh` inside the throwaway `drill` service on ports 9201/9203, with their own working directory and catalog `bacula_drill`; the restore goes to `drill-fd` on `dr-client` | `scripts/dr-drill.sh`, `config/drill/` |
| Offline master-key safe / DR recovery host | `dr-client` container (profile `drill`, drill network only, up only during a drill): generates the master keypair into the `keysafe` volume (mounted nowhere else), publishes `master.cert`, and runs `drill-fd` with the master keypair | `docker-compose.yml`, `docker/entrypoint-drclient.sh`, `config/drill/bacula-fd-drill.conf` |
| Corporate mail server | `smtp` container running Python 2.7 `python -u -m smtpd -n -c DebuggingServer 0.0.0.0:25` (unbuffered) with stdout logged to the `maillog` volume. Tests poll the log. | `docker-compose.yml`, `docker/entrypoint-smtp.sh` |
| Tape library | Bacula `File` device (disk volumes) | `config/bacula-sd.conf` |
| Production server being backed up | `server01` container running `bacula-fd` over a fixture tree in `/srv/data` (`tests/fixtures/data/`) | `docker-compose.yml` |
| `bconsole` / Director in unit tests | `tests/unit/stubs/bconsole`, a Bash stub on `PATH`. For each call it takes the next fixture name from the `$BCONSOLE_SEQUENCE` file, prints `tests/fixtures/bconsole/<name>`, and appends its stdin to `$BCONSOLE_LOG`. The fixtures are hand-written in Bacula 5.2.6 output format. | bats unit tests |
| `rsync`, `bsmtp`, `bextract`, `mysql`, Bacula daemons in unit tests | Recording stubs in `tests/unit/stubs/` | bats unit tests |
| MySQL in Python unit tests | `mock.Mock` connection/cursor returning canned rows | `tests/python/test_catalog_report.py` |

The final README must state all of these.

## 9. Existing code inventory (`git ls-files` at HEAD)

| File | Decision | Reason |
|---|---|---|
| `README.md` | refactor | Keep the honest title and description. Regenerate from `tools/readme_template.md` in the last task, with an accurate Status and a Layout tree. |
| `config/bacula-dir.conf` | refactor | The resource structure is sound and is kept: JobDefs, full/incr/diff jobs, Verify, Restore, FileSet, Schedule, Pools, Messages. Changes: hard-coded IPs and `...123` passwords become `@PLACEHOLDERS@`; add the missing `Catalog` DB address and port. `Schedule` moves off the JobDefs, because keeping it there would run all three level jobs every night; it goes onto a single new `server01-backup` job. The `backup-fd` client and the `BackupCatalog` job are added. Verify level `Catalog` (which needs a prior InitCatalog) becomes `VolumeToCatalog`, and Verify gets the `Pool` that 5.2.6 requires. The FileSet points at `/srv/data` and `/etc`. The Messages resource is aimed at the SMTP sink. |
| `scripts/backup.sh` | refactor | Keep its CLI shape (`<client> <type>`), logging, job naming `${CLIENT}-${TYPE}`, Verify-after-backup and mail notification. Fixes: `systemctl`, which does not exist on sysvinit wheezy; trusting `bconsole`'s exit status, which is always 0 whatever the job result; predictable `/tmp` script names, which become direct piping; no validation of the backup type; the hard-coded `df /backup`. Move the helpers into `scripts/lib/common.sh`. |

No files are deleted. All new files are listed per task in `docs/IMPLEMENTATION_PLAN.md`.

## 10. Test strategy

Everything runs inside `backup-recovery:wheezy` via `make`.

- **`make lint`** (tools container, no daemons):
  - `bash -n` on every `*.sh`, and `python -m py_compile` on `bin/*.py`.
  - Clears `build/` and runs `scripts/gen-keys.sh build/keys server01`, which writes both key sets including `master.pem` (the drill-fd config is rendered with `KEY_DIR=/src/build/keys`, so its `PKI Keypair` is `build/keys/master.pem`).
  - Renders the configs with `config/bacula.env.example` and `config/passwords.env.example` (`KEY_DIR=/src/build/keys`).
  - Runs `bacula-sd -t`, `bacula-fd -t`, `bconsole -t` and the drill SD/FD `-t` on the rendered files. `bacula-dir -t` is **not** run here, because 5.2.6 needs a catalog connection for it.
- **`make unit`**:
  - bats 0.3.1 suites in `tests/unit/`, covering `render-config.sh`, `lib/common.sh` parsers, and `backup.sh`/`restore.sh`/`restore-test.sh`/`queue-verify.sh`/`make-manifest.sh`/`gen-keys.sh`/`offsite-sync.sh`/`dr-drill.sh`/`drill-run.sh`/`split-secrets.sh`/`check-container-env.sh` argument handling and control flow, `keydir_check` and the key-directory refusals of the entrypoints, symlink refusals in `check_manifest`, `restore-test.sh` and `dr-drill.sh`, and static checks of `docker-compose.yml` (profiles, networks, per-service secrets, mounts). These run against the `bconsole` stub, fixture transcripts and the other stubs.
  - `nosetests tests/python`: `catalog_report.py` logic with a mocked DB.
  - No daemons are needed.
- **`make integration`**:
  - `scripts/stack-test.sh`: `dr-client init` creates the master keypair, then `docker compose up -d` (catalog, director, server01, smtp, offsite). It waits up to 120 s for `bconsole status dir`, runs `docker compose exec director bats /src/tests/integration`, starts `dr-client`, runs `tests/drill` in the `drill` service, repeats `96-secrets.bats` in the director while `dr-client` is up, and runs `scripts/check-container-env.sh` over every container (no password-like variable or password value in `docker inspect` environments).
  - **Access mechanism:** all integration tests run inside the `director` container and reach other containers only through the network daemons (bconsole, MySQL, rsync) and the shared named volumes in §4. No test needs a Docker CLI, socket or SSH.
    - Client data is read and changed under `/clientdata/server01`.
    - Restores go to server01 paths under `/restores` (or in place with `--where /`) and are checked on the same path locally.
    - Mail is read from `/var/log/smtp-sink/smtp.log`.
    - The offsite copy is checked with `rsync --list-only rsync://bacula@offsite/bacula/` (password file) and read from `/offsite`; anonymous and wrong-password access must fail.
    - Key separation is checked from the director: no PEM private key anywhere it can read (including volumes, restores and the offsite copy), and `estimate ... fileset=KeyDirFileSet listing` on server01 shows its keypair and `master.cert` but no `master.key`/`master.pem`.
    - Forced failures use the `server01-fail` job, so no container is ever stopped.
    - `tests/integration/helpers.bash` provides `bcon` (bconsole wrapper), `run_and_wait JOB [args]`, `last_jobid NAME`, `wait_for_file_match FILE REGEX SECS` and `sql QUERY`.
  - The suites cover:
    - `bacula-dir -t` against the live catalog; director, both clients and storage are reachable.
    - Scheduled jobs are `server01-backup` and `BackupCatalog`, and no level-named job.
    - A full backup ends `T`, and `parse_jobid`/`job_status` work on real bconsole output.
    - Encryption: the marker is found in the `Default-*` volume written by `plaintext-control` (control case) and absent from the `Full-*` volume written by server01. A restore of server01 data to `backup-fd`, which has no keypair, logs a message matching `No private decryption keys|Missing private key` (5.2.6 logs `No private decryption keys have been defined...` when the FD has no keypair loaded) and does not produce the plaintext.
    - An in-place restore and a single-file restore match their checksums.
    - One verify per backup (scheduled path and `backup.sh` path), and a tampered manifest fails the restore test.
    - `catalog_report.py` returns 0 after good jobs and 2 after `server01-fail`.
    - A mail appears in the SMTP sink log.
    - The offsite copy has volumes, bsr files and the dump.
    - Secrets: the director holds only its own secret file and no recovery-daemon or drill password.
    - The DR drill (`tests/drill/10-drill.bats`, run in the `drill` service) passes through `drill-fd` on `dr-client`, which also shows the master key decrypts; its MySQL account cannot read the live catalog, and the service holds no other service's password and no private key.
  - Finally `docker compose down -v`.
- **`make test`** = `lint` + `unit` + `integration`. Every task's acceptance command is a `make` target.

## 11. Known limitations that will remain

- The base image is the final wheezy build (7.11, 2016), so base libraries already in the image (libc, bash, coreutils) are newer than January 2014. Everything apt installs comes only from the 2014-01-31 snapshot suites, and the packages that matter are pinned exactly.
- Package authenticity is checked against the Debian archive signatures of January 2014 (made with keys that have expired since) and the SHA256 sums they cover; the build trusts `debian-archive-keyring` of the pinned `bookworm-slim` build stage.
- One Director/SD, one client, disk volumes only. No tape, no Windows, no daemon TLS. PKI encrypts file contents only: file names, attributes and the control channel are not encrypted.
- The offsite site, mail server, client host and DR recovery host are containers or scratch daemons on one Docker network (see §8), not real remote systems. The master key sits in a Docker volume mounted only into `dr-client`, standing in for an offline safe; that container runs only during a drill.
- Each lab container receives only its own passwords (§4), but the files are plain secrets on the Docker host's disk (`secrets/`, mode 0600) and the `drill` service still holds the recovery daemon's password and its scratch-catalog account.
- Scheduled runs (23:05, 23:30) are configured and listed, but tests do not wait for wall-clock schedules. They trigger the same jobs explicitly.
- Integration tests depend on `snapshot.debian.org` being reachable when the image is built.
- The images are amd64-only. On ARM hosts they run under emulation and are slow.

# backup-recovery: Implementation Plan

Each task below is exactly one commit, and every commit leaves `make test` green. Tasks come in dependency order. Tests are written before the code they cover. See `docs/SPEC.md` for interfaces, pins and resource names.

Conventions:
- The image is `backup-recovery:wheezy`, built by `make image`.
- `make unit` and `make lint` run in a throwaway `tools` container.
- `make integration` brings up the compose stack, runs `tests/integration/*.bats` inside `director`, and tears the stack down. Integration tests reach other containers only through Bacula/MySQL/rsync network daemons and the shared named volumes in SPEC §4, never through a Docker CLI or SSH (SPEC §10).
- The repo is bind-mounted at `/src` in every service. Bacula `Run*` script paths use `@SCRIPT_DIR@` (= `/src/scripts`).
- `make test` = `lint unit integration`. Until T5 adds the stack, `integration` runs `tests/integration/00-image.bats` in the tools container.

---

## T1: Scaffold Docker image, Makefile and test harness

- **Goal:** `make test` works from the first commit, inside the period image, with Bats 0.3.1, Python 2.7 test tools and all pinned Debian packages installed.
- **Files:**
  - create:
    - `Dockerfile`: FROM `debian:wheezy`. Sets up apt as described in SPEC §7:
      - Replaces `/etc/apt/sources.list` with exactly these two lines, with no archive.debian.org:
        ```
        deb http://snapshot.debian.org/archive/debian/20140131T000000Z wheezy main
        deb http://snapshot.debian.org/archive/debian-security/20140131T000000Z wheezy/updates main
        ```
      - Writes `/etc/apt/preferences` (`Package: *`, `Pin: origin snapshot.debian.org`, `Pin-Priority: 1001`) and `Acquire::Check-Valid-Until "false"`.
      - Preseeds dbconfig off.
      - Runs `apt-get install --force-yes` with every name in the SPEC §6 pin list as `pkg=version`. There are no globs:
        - `bacula-common bacula-common-mysql bacula-director-common bacula-director-mysql bacula-sd bacula-sd-mysql bacula-fd bacula-console` `=5.2.6+dfsg-9`
        - `mysql-server mysql-server-5.5 mysql-server-core-5.5 mysql-client-5.5 mysql-common libmysqlclient18` `=5.5.35+dfsg-0+wheezy1`
        - `openssl libssl1.0.0` `=1.0.1e-2+deb7u3`
        - `python2.7 python2.7-minimal libpython2.7` `=2.7.3-6`
        - `python-mysqldb=1.2.3-2`, `python-mock=0.8.0-3`, `python-nose=1.1.2-3`, `rsync=3.0.9-4`, `make=3.81-8.2`
      - Uses `ADD` for the bats v0.3.1 tarball, then a sha256 check and `install.sh /usr/local`.
    - `docker-compose.yml` (only a `tools` service for now, repo bind-mounted at `/src`)
    - `Makefile` (targets `image lint unit integration test clean`; creates `config/bacula.env` from the example when it is missing)
    - `requirements.txt` (`MySQL-python==1.2.3`, `mock==0.8.0`, `nose==1.1.2`; documentation of the pins, installed from Debian packages)
    - `.gitignore` (`config/bacula.env`, `build/`, `keys/`)
    - `tests/unit/00-toolchain.bats`
    - `tests/integration/00-image.bats`
    - `tests/python/__init__.py`
    - `tests/python/test_toolchain.py`
- **Tests to write first:**
  - `00-toolchain.bats`:
    - `bash --version` reports 4.2, `bacula-dir -?` reports `5.2.6`, `mysqld --version` reports `5.5.35`, `rsync --version` reports `3.0.9`, and `openssl version` reports `1.0.1e`.
    - `dpkg-query -W -f '${Package} ${Version}\n'` over every package in the SPEC §6 pin list returns exactly the pinned version. The list includes the transitive `libssl1.0.0 1.0.1e-2+deb7u3`, `libmysqlclient18`, `mysql-common`, `mysql-client-5.5` and `mysql-server-core-5.5` at `5.5.35+dfsg-0+wheezy1`, and `python2.7-minimal`/`libpython2.7` at `2.7.3-6`. This catches a newer build that `openssl version` alone would hide.
    - `/etc/apt/sources.list` contains no `archive.debian.org` or `deb.debian.org` line.
  - `test_toolchain.py` asserts `sys.version_info[:3] == (2, 7, 3)`, `MySQLdb.__version__ == '1.2.3'` and `mock.__version__ == '0.8.0'`.
  - `00-image.bats` asserts that `bats --version` equals `Bats 0.3.1`.
- **Acceptance:** `make image && make test`
- **Commit:**
  ```
  Add wheezy Docker image, Makefile and test harness

  Pins Bacula 5.2.6, MySQL 5.5.35, Python 2.7.3 and their direct
  library dependencies to the Debian snapshot and wires bats/nose into
  make test.
  ```

## T2: Template Bacula configs and add config renderer

- **Goal:** Real configs for all four Bacula components, with no hard-coded secrets or IPs. SD, FD and bconsole configs pass `-t` in lint. The Director config is parse-checked from T5, because `bacula-dir -t` in 5.2.6 needs a live catalog.
- **Files:**
  - create:
    - `scripts/render-config.sh`
    - `config/bacula-sd.conf` (device `FileStorage`, `Media Type = File`, `LabelMedia = yes`)
    - `config/bacula-fd.conf`
    - `config/bconsole.conf`
    - `config/bacula.env.example` (includes `KEY_DIR=/src/build/keys`, `SCRIPT_DIR=/src/scripts`)
    - `tests/unit/render-config.bats`
    - `tests/unit/config-syntax.bats`
  - modify:
    - `config/bacula-dir.conf`:
      - placeholders; Director name `backup-dir`; Catalog `DB Address`/`DB Port`
      - `DefaultJob`/`ServerFileSet`/`WeeklyCycle` names from SPEC §5.2
      - **`Schedule` removed from the JobDefs**; new `server01-backup` job with `Schedule = WeeklyCycle` and `Full Backup Pool = FullPool`, `Differential Backup Pool = DifferentialPool`, `Incremental Backup Pool = IncrementalPool`; the three level-named jobs stay unscheduled
      - `Verify-server01`: level `VolumeToCatalog`, **`Pool = Default`** (required in 5.2.6)
      - pools get `Label Format` (`Full-`, `Diff-`, `Incr-`, `Default-`)
      - FileSet `/srv/data` and `/etc` with the two Options blocks from SPEC §5.2 (`*secret.txt` uncompressed first, then GZIP)
      - Messages `mailcommand` to `@SMTP_HOST@`
      - `Maximum Concurrent Jobs = 1` for deterministic tests
    - `Makefile`: `lint` renders the configs into `build/` and runs `bacula-sd -t`, `bacula-fd -t` and `bconsole -t`. It does not run `bacula-dir -t`.
- **Tests to write first:**
  - `render-config.bats`: substitutes every placeholder; exits 3 when a variable is unset; exits 3 when a stray `@FOO@` remains; leaves values containing `/` and `&` intact.
  - `config-syntax.bats`:
    - `bacula-sd -t -c build/bacula-sd.conf`, `bacula-fd -t` and `bconsole -t` all exit 0.
    - No rendered file contains `Password123` or `192.168.`.
    - Static checks on rendered `bacula-dir.conf`: only `server01-backup` and `BackupCatalog` Job blocks carry `Schedule` (BackupCatalog from T11), the `JobDefs` block has no `Schedule`, and every `Job` block has a `Pool` or `JobDefs` line.
- **Acceptance:** `make lint unit`
- **Commit:**
  ```
  Template Bacula configs and add placeholder renderer

  Replaces hard-coded IPs and passwords with @VARS@ filled from an env
  file, adds SD/FD/bconsole configs, and moves the schedule onto a
  single job so only one client backup runs per night.
  ```

## T3: Extract shared bconsole helpers into scripts/lib/common.sh

- **Goal:** Testable parsing of bconsole output, so scripts can tell whether a job actually succeeded.
- **Files:**
  - create:
    - `scripts/lib/common.sh` (`log_message`, `die`, `bconsole_cmd`, `parse_jobid`, `wait_job`, `job_status`, `director_up`)
    - `tests/unit/stubs/bconsole`: on each call it reads the next fixture name from the `$BCONSOLE_SEQUENCE` file (one name per line; a cursor file in `$BATS_TMPDIR` tracks the position), prints `tests/fixtures/bconsole/<name>`, and appends its stdin to `$BCONSOLE_LOG`.
    - `tests/fixtures/bconsole/`: hand-written in Bacula 5.2.6 output format, because the stack does not exist yet. Files: `run-queued.txt`, `list-jobid-T.txt`, `list-jobid-f.txt`, `list-jobid-R.txt`, `status-dir-ok.txt`, `status-dir-refused.txt`. T5 checks the parsers against real output.
    - `tests/unit/common.bats`
- **Tests to write first:** `common.bats`:
  - `parse_jobid` extracts 42 from "Job queued. JobId=42" and returns non-zero when there is no JobId.
  - `job_status` returns `T` and `f` from the list fixtures.
  - `wait_job` polls through a `list-jobid-R.txt`, `list-jobid-T.txt` sequence and returns once the status is terminal.
  - `director_up` returns 0 and 1 against the status fixtures.
  - `log_message` writes a timestamped line to `$LOG_FILE`.
- **Acceptance:** `make unit`
- **Commit:**
  ```
  Add shared shell library for driving bconsole

  Parses JobId and JobStatus from bconsole output so scripts can report
  real job results instead of trusting bconsole's exit code.
  ```

## T4: Refactor backup.sh to check real job status

- **Goal:** Keep the `backup.sh <client> <type>` CLI, but make its exit codes truthful (SPEC §5.3) and make it run on sysvinit wheezy. Mail notification is left to T10.
- **Files:**
  - create:
    - `config/backup.conf.example` (`BCONSOLE_CONF`, `LOG_FILE`, `VOLUME_DIR`, `MIN_FREE_KB`)
    - `tests/unit/backup.bats`
  - modify: `scripts/backup.sh`
    - source `lib/common.sh`
    - validate the type against full, incremental and differential
    - replace `systemctl` with `director_up`
    - drop the temp files and pipe into bconsole instead
    - `wait_job`, then check the status is `T`
    - queue `Verify-<client>` itself (the only verify trigger for on-demand runs); optional `--no-verify`
    - free-space check on `$VOLUME_DIR`
    - the old mail call is removed here and comes back as `bsmtp` in T10
- **Tests to write first:** `backup.bats` (with the stub bconsole):
  - usage error exits 2.
  - bad type exits 2.
  - director down exits 3.
  - job `T` plus verify `T` exits 0, and the stub log shows `run job="server01-full" yes` followed by exactly one `run job="Verify-server01" yes`.
  - job `f` exits 1.
  - verify `f` exits 4.
  - `--no-verify` skips the verify job.
  - low disk space logs a WARNING.
- **Acceptance:** `make lint unit`
- **Commit:**
  ```
  Make backup.sh wait for jobs and report real status

  Drops the systemctl check (wheezy is sysvinit), validates the level,
  waits on the JobId and exits non-zero on failed backup or verify.
  ```

## T5: Add compose stack with MySQL catalog, director and client

- **Goal:** Real Bacula daemons running end to end: catalog, dir+sd+fd (`backup-fd`), the client fd, and an SMTP sink. The Director config parses against the live catalog, a full backup of `server01` ends in `T`, and the configured schedule is visible.
- **Files:**
  - create:
    - `docker/entrypoint-catalog.sh`: starts mysqld, creates the `bacula` DB and user (with rights to create and drop `bacula_drill` for T12), and runs `/usr/share/bacula-director/make_mysql_tables`.
    - `docker/entrypoint-director.sh`: sources `config/bacula.env`, renders the configs **into `/etc/bacula/`** (where `make_catalog_backup.pl`/`dbcheck` read them), waits for MySQL, starts `bacula-sd`, `bacula-fd` (client `backup-fd`) and `bacula-dir -f`.
    - `docker/entrypoint-client.sh`: renders the fd config into `/etc/bacula/`, copies fixtures into `/srv/data` when the volume is empty, and runs `bacula-fd -f`.
    - `config/bacula-fd-director.conf`: template for `backup-fd`, the FD on the director host. It has no PKI directives.
    - `docker/entrypoint-smtp.sh`: `python -u -m smtpd -n -c DebuggingServer 0.0.0.0:25 >> /var/log/smtp-sink/smtp.log 2>&1` (unbuffered).
    - `tests/fixtures/data/`: a small text/binary tree with a `docs/` subdirectory and `secret.txt` containing marker `PLAINTEXT-MARKER-7f3a`.
    - `tests/integration/helpers.bash`: `bcon`, `run_and_wait JOB [args]`, `last_jobid NAME`, `wait_for_file_match FILE REGEX SECS`, `sql QUERY`. It documents the access rules from SPEC §10.
    - `tests/integration/10-stack.bats`
    - `tests/integration/20-backup.bats`
  - modify:
    - `config/bacula-dir.conf`: adds Client `backup-fd`.
    - `Makefile`: `lint` also runs `bacula-fd -t` on the rendered `bacula-fd-director.conf`.
    - `docker-compose.yml`:
      - services `catalog`, `director`, `server01` and `smtp`, all on the `backupnet` network, with `/src` bind-mounted in each
      - named volumes `srvdata` (server01 `/srv/data`, director `/clientdata/server01`), `restores` (`/restores` in both) and `maillog` (smtp rw, director ro at `/var/log/smtp-sink`)
    - `Makefile`: `integration` does `compose up -d`, polls `bconsole status dir` for up to 120 s, then `compose exec director bats /src/tests/integration`, then `compose down -v`.
- **Tests to write first:**
  - `10-stack.bats`:
    - `bacula-dir -t -c /etc/bacula/bacula-dir.conf` exits 0 (live catalog).
    - `status dir` contains `backup-dir Version: 5.2.6`.
    - `status client=server01-fd` contains `server01-fd Version`, and `status client=backup-fd` succeeds.
    - `status storage=File` succeeds.
    - `status dir` "Scheduled Jobs" lists `server01-backup` and does **not** list `server01-full`, `server01-incremental` or `server01-differential`.
    - `show schedule=WeeklyCycle` contains the three Run lines.
  - `20-backup.bats`:
    - `scripts/backup.sh server01 full --no-verify` exits 0.
    - The catalog has at least one `Type='B'`, `Name='server01-full'` row with `JobStatus='T'` and `JobFiles > 0`.
    - `parse_jobid` on a real `run job=server01-full yes` output returns a number, and `job_status` on real `list jobid=N` output returns `T`. This checks the T3 fixtures against real 5.2.6 output.
- **Acceptance:** `make test`
- **Commit:**
  ```
  Add compose stack with MySQL catalog, director and client

  Runs bacula-dir/sd/fd, a client fd and MySQL 5.5 from the wheezy
  image, parses the Director config against the live catalog and proves
  the schedule listing and a full backup end to end.
  ```

## T6: Encrypt and sign client data with Bacula PKI

- **Goal:** The file daemon on `server01` encrypts and signs all data using a client keypair plus a master recovery key (SPEC §2 #4), and a control case shows that the volume check can actually see plaintext.
- **Files:**
  - create:
    - `scripts/gen-keys.sh`
    - `tests/unit/gen-keys.bats`
    - `tests/integration/30-encryption.bats`
  - modify:
    - `config/bacula-fd.conf`: `PKI Signatures = yes`, `PKI Encryption = yes`, `PKI Keypair = @KEY_DIR@/server01.pem`, `PKI Master Key = @KEY_DIR@/master.cert`.
    - `config/bacula-dir.conf`: adds FileSet `ControlFileSet` and the test-only job `plaintext-control` (Client `backup-fd`, Pool `Default`).
    - `docker/entrypoint-client.sh`: generates keys into the `keys` volume on first start and sets `KEY_DIR=/etc/bacula/keys` before rendering.
    - `docker-compose.yml`: adds the `keys` volume (server01 `/etc/bacula/keys`).
    - `Makefile`: `lint` does `rm -rf build/keys && scripts/gen-keys.sh build/keys server01` before `bacula-fd -t`, because 5.2.6 `bacula-fd -t` loads the PKI files.
- **Tests to write first:**
  - `gen-keys.bats`: creates `<client>.pem` (containing both `PRIVATE KEY` and `CERTIFICATE`), `master.cert` and `master.key`; the cert modulus matches the key (`openssl x509/rsa -modulus`); refuses to overwrite (exit 1); usage exits 2.
  - `30-encryption.bats`:
    - Control: `run job=plaintext-control yes` ends `T`, and `grep -l PLAINTEXT-MARKER-7f3a /var/lib/bacula/volumes/Default-*` finds it. This proves that an unencrypted, uncompressed copy of the marker is visible in a volume.
    - `backup.sh server01 full --no-verify` exits 0, and `grep -l PLAINTEXT-MARKER-7f3a /var/lib/bacula/volumes/Full-*` finds nothing. `secret.txt` matches the uncompressed Options block, so a missing marker here can only be due to encryption.
    - The Director log has no "Encryption error" for that JobId.
- **Acceptance:** `make test`
- **Commit:**
  ```
  Encrypt and sign client backups with Bacula PKI

  Adds an OpenSSL key generator for client and master recovery keys,
  enables FD data encryption, and checks the volumes against an
  unencrypted control backup of the same marker file.
  ```

## T7: Add non-interactive restore CLI

- **Goal:** `scripts/restore.sh` restores the latest backup or a point-in-time state, for the whole tree or selected files, without the interactive bconsole dialogue. It can also restore to a different FD.
- **Files:**
  - create:
    - `scripts/restore.sh`
    - `scripts/make-manifest.sh`
    - `tests/unit/restore.bats`
    - `tests/unit/make-manifest.bats`
    - `tests/integration/40-restore.bats`
  - modify: `config/bacula-dir.conf`, where `RestoreFiles` gets `Where = /tmp/bacula-restores`, the client, and the `Default` pool.
- **Tests to write first:**
  - `restore.bats` (with the stub bconsole):
    - `--dry-run` prints `restore client=server01-fd restoreclient=server01-fd where=/tmp/x select current all done yes`.
    - `--before` produces `before="2014-01-10 12:00:00"`.
    - `--jobid 5` produces `jobid=5`.
    - `--file a --file b` produces `file=a file=b` (no `all`).
    - `--restore-client backup-fd` produces `restoreclient=backup-fd`.
    - a missing `--client` exits 2.
    - a restore status of `f` exits 1.
  - `make-manifest.bats`: relative paths, sorted output, and `md5sum -c` passes from the root.
  - `40-restore.bats` (runs in the director and uses the shared volumes):
    - In-place restore:
      1. `make-manifest.sh /clientdata/server01 $BATS_TMPDIR/m`, then `backup.sh server01 full --no-verify`.
      2. `rm -rf /clientdata/server01/docs`.
      3. `restore.sh --client server01 --where /` restores into server01's `/srv/data`.
      4. `/clientdata/server01/docs` is back, and `md5sum -c` of the manifest from `/clientdata/server01` passes.
    - A `--file /srv/data/docs/<one file> --where /restores/t40-file` restore produces only that file under `/restores/t40-file/srv/data/`, and its checksum matches.
    - Negative decryption:
      1. `restore.sh --client server01 --restore-client backup-fd --file /srv/data/secret.txt --where /tmp/t40-nokey` targets the director's own FD, which has no keypair.
      2. `/var/log/bacula/bacula.log` for that JobId matches `No private decryption keys|Missing private key`. `backup-fd` loads no keypair, so 5.2.6 `restore.c` logs `No private decryption keys have been defined to decrypt encrypted backup data.`; the `Missing private key` form appears only when keys are loaded but none matches.
      3. `/tmp/t40-nokey/srv/data/secret.txt` either does not exist or does not contain `PLAINTEXT-MARKER-7f3a`.
- **Acceptance:** `make test`
- **Commit:**
  ```
  Add non-interactive restore CLI

  Builds bconsole restore commands for latest, point-in-time, jobid,
  single-file and cross-client restores and waits for the job to finish.
  ```

## T8: Add verify job trigger and automated restore test

- **Goal:** Catch bad backups before they are needed: exactly one VolumeToCatalog verify per backup, and a restore test that compares checksums.
- **Files:**
  - create:
    - `scripts/restore-test.sh`
    - `tests/unit/restore-test.bats`
    - `tests/integration/50-verify.bats`
  - modify: `config/bacula-dir.conf`
    - `server01-backup` (the scheduled job **only**, not the JobDefs) gets `RunScript { RunsWhen = After; RunsOnFailure = No; Console = "run job=Verify-server01 yes" }`.
    - `Verify-server01` gets its own priority.
    - The level-named jobs used by `backup.sh` get no RunScript, because `backup.sh` queues their verify itself.
- **Tests to write first:**
  - `restore-test.bats`: all checksums match exits 0; a changed file exits 1 and names it; a missing file exits 1; a missing manifest exits 2; the `--where`/`--root` path is passed through correctly.
  - `50-verify.bats`:
    - Scheduled path: record the number of `Verify-server01` rows, then `run job=server01-backup level=Incremental yes` and wait. Exactly one new `Verify-server01` row appears with `JobId` greater than the backup's JobId and status `T`.
    - Manual path: `backup.sh server01 incremental` (with verify) exits 0, and the `Verify-server01` row count grows by exactly one.
    - `restore-test.sh --client server01 --manifest <real> --where /restores/t50` exits 0.
    - With a tampered manifest it exits 1.
- **Acceptance:** `make test`
- **Commit:**
  ```
  Add VolumeToCatalog verify trigger and restore-test script

  Queues one verify after each scheduled backup, restores into a
  scratch directory and compares MD5 sums with a backup-time manifest.
  ```

## T9: Add Python catalog health report

- **Goal:** `bin/catalog_report.py` (Python 2.7, MySQLdb) reports failed backup/verify jobs and stale clients, with Nagios-style exit codes 0/1/2/3.
- **Files:**
  - create:
    - `bin/catalog_report.py`: pure functions `classify(rows, now, max_age, since)` and `render(result, fmt)`, with a thin `main()` that uses MySQLdb. Only `Type IN ('B','V')` jobs are counted.
    - `tests/python/test_catalog_report.py`
    - `tests/integration/60-report.bats`
  - modify:
    - `config/bacula-dir.conf`: adds the test-only job `server01-fail` (`JobDefs = DefaultJob`, `ClientRunBeforeJob = "/bin/false"`, no Schedule).
    - `Makefile`: `lint` adds `py_compile`.
- **Tests to write first:**
  - `test_catalog_report.py` (unittest plus mock 0.8):
    - all `T` and recent gives OK/0.
    - the last success older than max-age gives WARNING/1.
    - an `f`/`E` backup or verify job inside the window gives CRITICAL/2.
    - a failed restore (`Type='R'`) is ignored.
    - a client with no jobs is stale.
    - `--format nagios` prints a single `BACULA OK - ...|` line.
    - the SQL is executed with parameters (checked on the mock cursor), not string formatting.
    - a DB connect error gives UNKNOWN/3.
  - `60-report.bats`:
    - after the earlier good jobs, the exit code is 0.
    - `run job=server01-fail yes` ends within seconds with status `f`, and the report then exits 2 and names `server01-fail`. No container is stopped, so the later suites still have server01.
- **Acceptance:** `make test`
- **Commit:**
  ```
  Add Python catalog report for failed and stale backups

  Queries the Bacula MySQL catalog read-only and exits with Nagios-style
  codes so missed or failed backups surface automatically.
  ```

## T10: Route job notifications to the SMTP sink

- **Goal:** Bacula Messages resources and `backup.sh` send mail through `bsmtp`, and the tests see it arrive. This task owns all `bsmtp` work.
- **Files:**
  - create:
    - `tests/unit/stubs/bsmtp`
    - `tests/integration/70-notify.bats`
  - modify:
    - `config/bacula-dir.conf`: `mailcommand`/`operatorcommand` use `bsmtp -h @SMTP_HOST@`, and `mail = @ADMIN_EMAIL@ = all, !skipped`.
    - `config/backup.conf.example`: adds `ADMIN_EMAIL` and `SMTP_HOST`.
    - `scripts/backup.sh`: sends the summary via `bsmtp` when `SMTP_HOST` is set.
    - `tests/unit/backup.bats`: covers the notification call through the stub `bsmtp`.
- **Tests to write first:**
  - The `backup.bats` case where `bsmtp` is invoked with `-h $SMTP_HOST` and a subject containing the client and level, and the case where it is not invoked when `SMTP_HOST` is unset.
  - `70-notify.bats`: after `backup.sh server01 incremental --no-verify`, `wait_for_file_match /var/log/smtp-sink/smtp.log 'Subject: Bacula: Backup OK of server01-fd' 30` and `... 'Backup completed for server01' 30` both succeed. They poll the log once a second for up to 30 s.
- **Acceptance:** `make test`
- **Commit:**
  ```
  Send Bacula and backup.sh notifications through bsmtp

  Points Messages resources and the wrapper script at an SMTP host and
  tests delivery against a local Python smtpd sink.
  ```

## T11: Back up the catalog and sync to offsite host

- **Goal:** A nightly `BackupCatalog` job on client `backup-fd` dumps MySQL, backs up the dump, and uses rsync to copy volumes, `.bsr` files and the dump to the `offsite` container.
- **Files:**
  - create:
    - `scripts/offsite-sync.sh`
    - `config/rsyncd.conf`
    - `docker/entrypoint-offsite.sh`
    - `tests/unit/stubs/rsync`
    - `tests/unit/offsite-sync.bats`
    - `tests/integration/80-offsite.bats`
  - modify:
    - `config/bacula-dir.conf`:
      - adds FileSet `CatalogFileSet` (`/var/lib/bacula/bacula.sql`, MD5, no compression).
      - adds the `BackupCatalog` job: `Client = backup-fd`, **`Pool = Default`**, `Schedule = WeeklyCycleAfterBackup`, `Write Bootstrap = /var/lib/bacula/BackupCatalog.bsr`, `RunBeforeJob = "/etc/bacula/scripts/make_catalog_backup.pl MyCatalog"` (reads `/etc/bacula/bacula-dir.conf`, rendered there by `entrypoint-director.sh`), `RunAfterJob = "@SCRIPT_DIR@/offsite-sync.sh"`.
      - sets `Write Bootstrap` for every job.
    - `docker-compose.yml`: adds the `offsite` service and the `offsite` volume (offsite `/offsite` rw, director `/offsite` ro).
- **Tests to write first:**
  - `offsite-sync.bats` (with the stub `rsync` on PATH): passes `-a` and the right sources and destinations (`volumes/`, `bsr/`, `db/`); propagates a non-zero rsync exit; `--dest` overrides the default.
  - `80-offsite.bats`:
    - `run job=BackupCatalog yes` ends `T`.
    - `rsync --list-only rsync://offsite/bacula/volumes/` lists a `Full-*` volume.
    - `rsync --list-only rsync://offsite/bacula/bsr/` lists `server01-fd.bsr` and `BackupCatalog.bsr`.
    - `rsync --list-only rsync://offsite/bacula/db/` lists `bacula.sql`.
    - `/offsite/db/bacula.sql` has a size greater than 0.
- **Acceptance:** `make test`
- **Commit:**
  ```
  Back up the catalog and rsync volumes to an offsite host

  Adds a BackupCatalog job whose after-script copies volumes, bootstrap
  files and the catalog dump to a simulated offsite rsync daemon.
  ```

## T12: Add disaster-recovery drill from offsite copy

- **Goal:** Prove that the offsite copy plus the master recovery key can restore data with no help from the live Director. The drill:
  - uses `bextract` with `BackupCatalog.bsr` to recover the unencrypted catalog dump,
  - loads that dump into a scratch catalog,
  - restores the encrypted `server01` data through a scratch Director/SD/FD whose FD holds only the master key (SPEC §2 #8, §5.3).
- **Files:**
  - create:
    - `scripts/dr-drill.sh`
    - `config/drill/bacula-dir-drill.conf` (`drill-dir` :9201, catalog `bacula_drill`, Clients `server01-fd` and `drill-fd`, Storage `File` → `drill-sd`, Pool `Default`, a `RestoreFiles` job)
    - `config/drill/bacula-sd-drill.conf` (`drill-sd` :9203, device `FileStorage`, `Media Type = File`, over the scratch copy of `/offsite/volumes`; also used by `bextract -c`)
    - `config/drill/bacula-fd-drill.conf` (`drill-fd` :9202, `PKI Encryption = yes` and `PKI Keypair = <scratch>/master.pem`. 5.2.6 `bacula-fd` loads the keypair into its decryption recipients only when `PKI Encryption` or `PKI Signatures` is on. server01's signatures take the no-signer path in `verify_signature()`, which only logs a debug message, so the data still restores)
    - `tests/unit/stubs/bextract`, `tests/unit/stubs/mysql` and stubs for `bacula-dir`, `bacula-sd` and `bacula-fd`
    - `tests/unit/dr-drill.bats`
    - `tests/integration/90-dr-drill.bats`
  - modify:
    - `docker-compose.yml`: the `keys` volume is also mounted read-only into `director` at `/keys` (simulated offline key safe).
    - `Makefile`: `lint` adds `bacula-sd -t`/`bacula-fd -t` on the rendered drill configs (`bacula-fd -t` loads the drill keypair, so the master pem is built from `build/keys/master.key` + `master.cert`, which lint already creates); adds a `dr-drill` convenience target.
- **Tests to write first:**
  - `dr-drill.bats` (with the stubs):
    - missing args exit 2.
    - a bextract failure exits 1.
    - a recovered `bacula.sql` that differs from `db/bacula.sql` exits 1.
    - an empty Job table exits 1.
    - a restore status of `f` exits 1.
    - a checksum mismatch exits 1.
    - on every failure path the trap stops the drill daemons and issues `DROP DATABASE bacula_drill` (checked in the stub logs).
  - `90-dr-drill.bats` (self-contained setup):
    - Setup: `make-manifest.sh /clientdata/server01 $BATS_TMPDIR/m`, `backup.sh server01 incremental --no-verify`, `run job=BackupCatalog yes` (syncs offsite).
    - `dr-drill.sh --offsite /offsite --manifest $BATS_TMPDIR/m --keys /keys` exits 0.
    - Its output contains `catalog dump recovered from volume: OK`, `catalog jobs:` with a count ≥ 1, and `files verified:` with the manifest's line count.
    - Afterwards `SHOW DATABASES` has no `bacula_drill`, and nothing listens on 9201-9203.
- **Acceptance:** `make test`
- **Commit:**
  ```
  Add disaster-recovery drill using the offsite copy

  Recovers the catalog dump with bextract, loads it into a scratch
  catalog and restores encrypted client data through a scratch file
  daemon holding only the master key, then checks it against the
  manifest.
  ```

## T13: Regenerate README from template

- **Goal:** An honest README built from `tools/readme_template.md`, with the template comment removed.
- **Files:**
  - modify: `README.md`, with these sections:
    - Title and a one-paragraph description.
    - "Personal project built on the 2013-era stack (Bacula 5.2.6, MySQL 5.5.35, Bash 4.2, Python 2.7.3, rsync 3.0.9 on Debian wheezy)".
    - Status/Implemented: one bullet per in-scope feature, each mapped to a script and a test.
    - Not implemented: the technical out-of-scope rows from SPEC §3 (tape, multiple/Windows clients, GUI, daemon TLS, real DR site, real mail server, systemd, cron, placeholder tree), plus the limitations in §11. The fabricated-metrics rows are **not** copied. At most a generic line such as "business-impact claims from an earlier draft were removed".
    - Mocks: an explicit list:
      - offsite site = rsync container
      - DR recovery host = scratch drill daemons
      - master-key safe = read-only volume
      - mail = Python smtpd sink
      - tape = disk File device
      - production server = `server01` container
      - bconsole and other binaries = stubs in unit tests
      - MySQL = mock in Python unit tests
    - Built with: pinned versions.
    - Running it: `docker compose up -d` plus `docker compose exec director /src/scripts/backup.sh server01 full`.
    - Tests: `make test`.
    - Layout: generated with this exact one-liner (no new file):
      ```
      git ls-files | awk -F/ '{p=""; for(i=1;i<NF;i++){p=p $i "/"; if(!(p in s)){s[p]=1; printf "%*s%s/\n", 2*(i-1), "", $i}} printf "%*s%s\n", 2*(NF-1), "", $NF}'
      ```
- **Tests to write first:** none new. The acceptance command checks the README against the repo.
- **Acceptance:**
  ```
  make test && ! grep -nE 'Etech|IT Administrator|Status-Complete|99\.9|Zero data loss|RTO|uptime|MTTR|Developed during|\{\{' README.md \
    && for f in $(grep -oE '(scripts|bin|config|docker|tests|docs)/[A-Za-z0-9_./-]+' README.md | sort -u); do test -e "$f" || { echo "missing $f"; exit 1; }; done
  ```
- **Commit:**
  ```
  Rewrite README from template with honest status

  Documents what is implemented and tested, what is simulated, and the
  file layout generated from git ls-files.
  ```

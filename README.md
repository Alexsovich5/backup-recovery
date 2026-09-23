# Automated Backup and Recovery System

Enterprise backup solution with automated scheduling, encryption, and disaster recovery capabilities.

Personal project, built to explore scripted Bacula backup scheduling and verification. It is not production software — see **Status** below for exactly what is and isn't implemented.

## Status

**Implemented**

- Backup shell script with scheduling and verification steps
- Bacula director configuration

**Not implemented / known limitations**

- Two files — this is a configuration sketch, not a system
- Never run against a real Bacula installation
- No restore-path testing

## Layout

```
config/
  bacula-dir.conf
scripts/
  backup.sh
```


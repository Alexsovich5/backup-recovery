#!/bin/bash
#
# Entrypoint of the "smtp" service: a mail sink. Python's DebuggingServer
# prints every message it receives; the output goes unbuffered to
# /var/log/smtp-sink/smtp.log (named volume "maillog").

mkdir -p /var/log/smtp-sink
exec python -u -m smtpd -n -c DebuggingServer 0.0.0.0:25 >> /var/log/smtp-sink/smtp.log 2>&1

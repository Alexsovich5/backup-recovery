IMAGE   := backup-recovery:wheezy
COMPOSE := docker compose -p backup-recovery
TOOLS   := $(COMPOSE) run --rm -T tools

# Templates in config/ rendered into build/ by lint.
CONFIGS := bacula-dir bacula-sd bacula-fd bacula-fd-director bconsole

# Drill templates in config/drill/, rendered into build/drill/ by lint.
DRILL_CONFIGS := bacula-dir-drill bacula-sd-drill bacula-fd-drill

.PHONY: image lint unit integration test clean env keys up drill

image:
	for i in 1 2 3; do docker build -t $(IMAGE) . && exit 0; sleep 5; done; exit 1

# Create the local settings file from the example when it is missing, and
# add any variable the example has gained since (existing values are kept).
# Passwords live in secrets/passwords.env, created the same way (a
# config/bacula.env that still holds passwords hands them over), and
# are split into one file per service under secrets/.
env:
	@if [ ! -f config/bacula.env ]; then \
	  cp config/bacula.env.example config/bacula.env; \
	  echo "created config/bacula.env from config/bacula.env.example"; \
	fi
	@for v in $$(sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' config/bacula.env.example); do \
	  grep -q "^$$v=" config/bacula.env || { \
	    grep "^$$v=" config/bacula.env.example >> config/bacula.env; \
	    echo "added $$v to config/bacula.env"; }; \
	done
	@mkdir -p secrets && chmod 700 secrets
	@if [ ! -f secrets/passwords.env ]; then \
	  (umask 077; : > secrets/passwords.env); \
	  grep '_PASSWORD=' config/bacula.env >> secrets/passwords.env || true; \
	  grep -v '_PASSWORD=' config/bacula.env > config/bacula.env.tmp && mv config/bacula.env.tmp config/bacula.env; \
	  echo "created secrets/passwords.env"; \
	fi
	@for v in $$(sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' config/passwords.env.example); do \
	  grep -q "^$$v=" secrets/passwords.env || { \
	    grep "^$$v=" config/passwords.env.example >> secrets/passwords.env; \
	    echo "added $$v to secrets/passwords.env"; }; \
	done
	@chmod 600 secrets/passwords.env
	@scripts/split-secrets.sh secrets/passwords.env secrets

lint: env
	$(TOOLS) bash -c 'set -e; \
	  for f in $$(find . -name "*.sh" -not -path "./.git/*" -not -path "./build/*"); do \
	    echo "bash -n $$f"; bash -n "$$f"; done; \
	  for f in $$(ls bin/*.py 2>/dev/null); do \
	    echo "py_compile $$f"; python -m py_compile "$$f"; done; \
	  mkdir -p build; \
	  (set -a; . config/bacula.env.example; . config/passwords.env.example; set +a; \
	   for c in $(CONFIGS); do \
	     echo "render config/$$c.conf"; \
	     scripts/render-config.sh config/$$c.conf build/$$c.conf; done); \
	  rm -rf build/keys && scripts/gen-keys.sh build/keys server01; \
	  rm -rf build/drill && mkdir -p build/drill/work; \
	  (set -a; . config/bacula.env.example; . config/passwords.env.example; DRILL_DIR=/src/build/drill; \
	   DRILL_PASSWORD=lint-only; DB_USER=lint-only; DRILL_RESTORE_DIR=/src/build/drill/restore; set +a; \
	   for c in $(DRILL_CONFIGS); do \
	     echo "render config/drill/$$c.conf"; \
	     scripts/render-config.sh config/drill/$$c.conf build/drill/$$c.conf; done); \
	  echo "bacula-sd -t"; bacula-sd -t -c build/bacula-sd.conf; \
	  echo "bacula-fd -t"; bacula-fd -t -c build/bacula-fd.conf; \
	  echo "bacula-fd -t (backup-fd)"; bacula-fd -t -c build/bacula-fd-director.conf; \
	  echo "bacula-sd -t (drill-sd)"; bacula-sd -t -c build/drill/bacula-sd-drill.conf; \
	  echo "bacula-fd -t (drill-fd)"; bacula-fd -t -c build/drill/bacula-fd-drill.conf; \
	  echo "bconsole -t"; bconsole -t -c build/bconsole.conf'

unit: env
	$(TOOLS) bash -c 'set -e; bats tests/unit; nosetests -v --exe tests/python'

# Creates the master keypair, brings the stack up, runs the integration
# suites in the director and the drill suite in the drill service, checks
# container environments for secrets, and always tears the stack down (with
# its volumes) afterwards, keeping the suites' exit status.
integration: env
	COMPOSE="$(COMPOSE)" scripts/stack-test.sh

test: lint unit integration

# Creates the master keypair on first use (dr-client runs once with "init"
# and publishes master.cert), then starts the stack. dr-client itself is
# not started: it only runs during a drill.
keys: env
	$(COMPOSE) --profile drill run --rm -T dr-client init

up: keys
	$(COMPOSE) up -d

# Runs the DR drill against the running stack ("make up" first): starts
# dr-client, runs the drill service against the offsite copy and a manifest
# of server01's current data, and stops dr-client again. The offsite copy
# must be newer than that data, e.g. right after BackupCatalog has run.
drill: env
	@status=0; \
	$(COMPOSE) --profile drill up -d dr-client || status=$$?; \
	[ $$status -ne 0 ] || $(COMPOSE) --profile drill run --rm -T drill || status=$$?; \
	$(COMPOSE) --profile drill rm -sf dr-client; \
	exit $$status

clean:
	$(COMPOSE) --profile drill down --remove-orphans
	rm -rf build
	find . -name '*.pyc' -delete

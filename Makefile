IMAGE   := backup-recovery:wheezy
COMPOSE := docker compose -p backup-recovery
TOOLS   := $(COMPOSE) run --rm -T tools

# Templates in config/ rendered into build/ by lint.
CONFIGS := bacula-dir bacula-sd bacula-fd bacula-fd-director bconsole

# Drill templates in config/drill/, rendered into build/drill/ by lint.
DRILL_CONFIGS := bacula-dir-drill bacula-sd-drill bacula-fd-drill

.PHONY: image lint unit integration test clean env dr-drill

image:
	for i in 1 2 3; do docker build -t $(IMAGE) . && exit 0; sleep 5; done; exit 1

# Create the local env file from the example when it is missing.
env:
	@if [ ! -f config/bacula.env ] && [ -f config/bacula.env.example ]; then \
	  cp config/bacula.env.example config/bacula.env; \
	  echo "created config/bacula.env from config/bacula.env.example"; \
	fi

lint: env
	$(TOOLS) bash -c 'set -e; \
	  for f in $$(find . -name "*.sh" -not -path "./.git/*" -not -path "./build/*"); do \
	    echo "bash -n $$f"; bash -n "$$f"; done; \
	  for f in $$(ls bin/*.py 2>/dev/null); do \
	    echo "py_compile $$f"; python -m py_compile "$$f"; done; \
	  mkdir -p build; \
	  (set -a; . config/bacula.env.example; set +a; \
	   for c in $(CONFIGS); do \
	     echo "render config/$$c.conf"; \
	     scripts/render-config.sh config/$$c.conf build/$$c.conf; done); \
	  rm -rf build/keys && scripts/gen-keys.sh build/keys server01; \
	  rm -rf build/drill && mkdir -p build/drill/work; \
	  (umask 077; cat build/keys/master.key build/keys/master.cert > build/drill/master.pem); \
	  (set -a; . config/bacula.env.example; DRILL_DIR=/src/build/drill; \
	   DRILL_PASSWORD=lint-only; set +a; \
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

# Brings the stack up, waits up to 120 s for the Director, runs the
# integration suites inside the director container and always tears the
# stack down (with its volumes) afterwards, keeping the suites' exit status.
integration: env
	@status=0; \
	$(COMPOSE) up -d || status=$$?; \
	[ $$status -ne 0 ] || echo "waiting for the Director (up to 120 s)"; \
	[ $$status -ne 0 ] || $(COMPOSE) exec -T director bash -c 'for i in $$(seq 60); do \
	    echo "status dir" | bconsole -c /etc/bacula/bconsole.conf 2>/dev/null \
	      | grep -q "^Daemon started " && exit 0; sleep 2; done; exit 1' || status=$$?; \
	if [ $$status -ne 0 ]; then \
	  echo "stack did not come up or the Director did not answer within 120 s"; \
	  $(COMPOSE) logs --tail=50; \
	else \
	  $(COMPOSE) exec -T director bats /src/tests/integration || status=$$?; \
	fi; \
	$(COMPOSE) down -v; \
	exit $$status

test: lint unit integration

# Runs the DR drill in the running stack ("docker compose up -d" first)
# against a manifest of server01's current data. The offsite copy must be
# newer than that data, e.g. right after BackupCatalog has run.
dr-drill: env
	$(COMPOSE) exec -T director bash -c 'set -e; \
	  m=$$(mktemp); trap "rm -f $$m" EXIT; \
	  /src/scripts/make-manifest.sh /clientdata/server01 $$m; \
	  /src/scripts/dr-drill.sh --offsite /offsite --manifest $$m --keys /keys'

clean:
	$(COMPOSE) down --remove-orphans
	rm -rf build
	find . -name '*.pyc' -delete

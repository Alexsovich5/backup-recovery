IMAGE   := backup-recovery:wheezy
COMPOSE := docker compose -p backup-recovery
TOOLS   := $(COMPOSE) run --rm -T tools

# Templates in config/ rendered into build/ by lint.
CONFIGS := bacula-dir bacula-sd bacula-fd bconsole

.PHONY: image lint unit integration test clean env

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
	  echo "bacula-sd -t"; bacula-sd -t -c build/bacula-sd.conf; \
	  echo "bacula-fd -t"; bacula-fd -t -c build/bacula-fd.conf; \
	  echo "bconsole -t"; bconsole -t -c build/bconsole.conf'

unit: env
	$(TOOLS) bash -c 'set -e; bats tests/unit; nosetests -v --exe tests/python'

integration: env
	$(TOOLS) bats tests/integration/00-image.bats

test: lint unit integration

clean:
	$(COMPOSE) down --remove-orphans
	rm -rf build
	find . -name '*.pyc' -delete

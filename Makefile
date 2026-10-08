IMAGE   := backup-recovery:wheezy
COMPOSE := docker compose -p backup-recovery
TOOLS   := $(COMPOSE) run --rm -T tools

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
	    echo "py_compile $$f"; python -m py_compile "$$f"; done'

unit: env
	$(TOOLS) bash -c 'set -e; bats tests/unit; nosetests -v --exe tests/python'

integration: env
	$(TOOLS) bats tests/integration/00-image.bats

test: lint unit integration

clean:
	$(COMPOSE) down --remove-orphans
	rm -rf build
	find . -name '*.pyc' -delete

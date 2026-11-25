# Test and lint the plugin. Nothing here downloads models or talks to a studio.
.PHONY: test lint check

test:
	node --test tests/model.test.mjs
	bash tests/ctl.test.sh

lint:
	shellcheck ctl.sh dev-sync.sh tests/ctl.test.sh

check: lint test

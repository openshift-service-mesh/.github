.PHONY: update
update:
	@cd downstream-changes;bash update.sh

.PHONY: gen
gen:
	@cd downstream-changes;SKIP_GIT=true bash update.sh

.PHONY: gen-check
gen-check: gen
	@if [ -n "$(shell git status --porcelain)" ]; then \
	  git status; git diff; \
	  echo "ERROR: Some files need to be updated, please run 'make gen' and include any changed files in your PR"; \
	  exit 1; \
	fi

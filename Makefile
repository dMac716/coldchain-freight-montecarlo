SHELL := /bin/bash

SCENARIO ?= CENTRALIZED
N ?= 5000
SEED ?= 123
MODE ?= REAL_RUN
RUN_GROUP ?= BASE

.PHONY: setup preflight test smoke local real aggregate bq clean-chunks derive-ui ui

setup:
	bash tools/bootstrap_local.sh

preflight:
	Rscript tools/preflight.R --mode $(MODE) --scenario $(SCENARIO) --run_group $(RUN_GROUP)

test:
	Rscript -e 'testthat::test_dir("tests/testthat")'

smoke:
	bash tools/smoke_test.sh

local:
	Rscript tools/run_local.R --scenario SMOKE_LOCAL --n 5000 --seed 123 --mode SMOKE_LOCAL --outdir outputs/local_smoke

real:
	Rscript tools/run_chunk.R --scenario $(SCENARIO) --n $(N) --seed $(SEED) --mode REAL_RUN --outdir outputs/check_real
	Rscript tools/aggregate.R --run_group $(RUN_GROUP) --mode REAL_RUN

aggregate:
	Rscript tools/aggregate.R --run_group $(RUN_GROUP) --mode $(MODE)

bq:
	bash tools/faf_bq/run_faf_bq.sh

clean-chunks:
	bash tools/clean_chunks.sh

derive-ui:
	Rscript tools/derive_ui_artifacts.R --top_n 200

ui: derive-ui
	quarto render site/

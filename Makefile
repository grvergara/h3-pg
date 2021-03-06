# Copyright 2018-2019 Bytes & Brains
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

EXTENSION = h3

# extract extension version from .control file
EXTVERSION = $(shell grep default_version $(EXTENSION).control | \
	sed -e "s/default_version[[:space:]]*=[[:space:]]*'\([^']*\)'/\1/")

# h3 core library version to clone and statically link
LIBH3_VERSION = v3.6.3
# directory that h3 core repository is cloned into
LIBH3_SOURCE = libh3-$(LIBH3_VERSION)
# h3 static library location
LIBH3_BUILD = $(LIBH3_SOURCE)/build
# sql files used for installation, update and testing
SQL_INSTALLS = $(wildcard sql/install/*.sql)
SQL_UPDATES = $(wildcard sql/updates/*.sql)
SQL_TESTS = $(wildcard test/sql/*.sql)
SQL_FULLINSTALL = sql/$(EXTENSION)--$(EXTVERSION).sql

# a shared library to build from multiple source files
MODULE_big = $(EXTENSION)
# object files to be linked together
OBJS = $(patsubst %.c,%.o,$(wildcard src/*.c))
# random files to install into $PREFIX/share/$MODULEDIR
DATA = $(SQL_UPDATES)
DATA_built = $(SQL_FULLINSTALL)
# will be added to MODULE_big link line
SHLIB_LINK += -lh3 -L$(LIBH3_BUILD)/lib
# will be added to CPPFLAGS
PG_CPPFLAGS += -I$(LIBH3_BUILD)/src/h3lib/include
# list of regression test cases (without suffix)
REGRESS = $(basename $(notdir $(SQL_TESTS)))
# additional switches to pass to pg_regress
REGRESS_OPTS = \
	--inputdir=test \
	--outputdir=test \
	--load-extension=postgis \
	--load-extension=h3
# extra files to remove in make clean
EXTRA_CLEAN += \
	$(LIBH3_SOURCE) \
	$(DATA_built) \
	src/extension.h \
	$(wildcard test/sql/ci-*.sql) \
	$(wildcard test/expected/ci-*.out) \
	$(wildcard *.BAK) \
	/tmp/extra-functions \
	/tmp/excluded-functions \
	test/regression.diffs test/regression.out test/results \
	h3-*.zip

# PGXS boilerplate
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

###########################################################################
# Non-standard PGXS stuff below
###########################################################################

$(OBJS): $(LIBH3_BUILD) src/extension.h

# targets for building H3 library internals
$(LIBH3_SOURCE):
	git clone --branch $(LIBH3_VERSION) --depth 1 \
	 	https://github.com/uber/h3 $(LIBH3_SOURCE)
$(LIBH3_BUILD): $(LIBH3_SOURCE)
	mkdir -p $(LIBH3_BUILD)
	cd $(LIBH3_BUILD) && cmake \
		-DCMAKE_C_FLAGS=-fPIC \
		-DBUILD_TESTING=OFF \
		-DENABLE_COVERAGE=OFF \
		-DENABLE_DOCS=OFF \
		-DENABLE_FORMAT=OFF \
		-DENABLE_LINTING=OFF \
		..
	cmake --build $(LIBH3_BUILD) --target h3
	cmake --build $(LIBH3_BUILD) --target binding-functions

# generate header file with extension version baked in
src/extension.h: src/extension.in.h
	sed -e 's/@EXTVERSION@/$(EXTVERSION)/g' \
		$< > $@

# generate full installation sql (from uninstalled to latest)
$(SQL_FULLINSTALL): $(sort $(SQL_INSTALLS))
	cat $^ > $@

# package for distribution
dist:
	git archive --prefix=h3-$(EXTVERSION)/ --output h3-dist.zip HEAD

###########################################################################
# Extra CI testing targets
###########################################################################

format: clean
	pgindent

# functions which we have decided not to provide bindings for
EXCLUDED_BINDING_FUNCTIONS = \
	degs_to_rads \
	rads_to_degs \
	to_string \
	string_to_h3

# functions provided that are not part of expected binding functions
EXTRA_BINDING_FUNCTIONS = \
	get_extension_version \
	to_children_slow \
	to_geo_boundary_geography \
	to_geo_boundary_geometry \
	to_geography \
	to_geometry

/tmp/excluded-functions:
	echo "$(EXCLUDED_BINDING_FUNCTIONS)" | tr " " "\n" > $@

/tmp/extra-functions:
	echo "$(EXTRA_BINDING_FUNCTIONS)" | tr " " "\n" > $@

# rules for testing the update path against full install for functions
test/sql/ci-install.sql: $(SQL_FULLINSTALL)
	echo "\df *h3*" > $@
test/expected/ci-install.out: $(SQL_UPDATES)
	psql -c "DROP DATABASE IF EXISTS pg_regress;"
	psql -c "CREATE DATABASE pg_regress;"
	psql -d pg_regress -c "CREATE EXTENSION postgis;"
	psql -d pg_regress -c "CREATE EXTENSION h3 VERSION '0.1.0';"
	psql -d pg_regress -c "ALTER EXTENSION h3 UPDATE;"
	echo "\df *h3*" > $@
	psql -d pg_regress -c "\df *h3*" >> $@
	psql -c "DROP DATABASE pg_regress;"

# rules for testing the update path against full install for operators
test/sql/ci-operators.sql: $(SQL_FULLINSTALL)
	echo "\do" > $@
test/expected/ci-operators.out: $(SQL_UPDATES)
	psql -c "DROP DATABASE IF EXISTS pg_regress;"
	psql -c "CREATE DATABASE pg_regress;"
	psql -d pg_regress -c "CREATE EXTENSION postgis;"
	psql -d pg_regress -c "CREATE EXTENSION h3 VERSION '0.1.0';"
	psql -d pg_regress -c "ALTER EXTENSION h3 UPDATE;"
	echo "\do" > $@
	psql -d pg_regress -c "\do" >> $@
	psql -c "DROP DATABASE pg_regress;"

# generate expected bindings from h3 generated binding function list
test/expected/ci-bindings.out: $(LIBH3_BUILD)/binding-functions /tmp/excluded-functions
	psql -c "DROP DATABASE IF EXISTS pg_regress;"
	psql -c "CREATE DATABASE pg_regress;"
	echo "\\\echo '$(shell \
	    cat ${LIBH3_BUILD}/binding-functions \
        | sed -r 's/\bh3//g' \
        | sed -r 's/([A-Z]|[0-9]+)/_\L\1/g' | sed 's/^_//' \
        | sed -r 's/h_3/h3/g' \
        | sed -r 's/i_i_i/iii/g' \
        | sed -e 's/\(.*\)/\L\1/' \
        | grep -v -x -F -f /tmp/excluded-functions \
        | sort | uniq \
	)'" > /tmp/ci-bindings.out
	cat /tmp/ci-bindings.out > $@
	psql -d pg_regress -f /tmp/ci-bindings.out >> $@
	psql -c "DROP DATABASE pg_regress;"

# generate actual bindings from installed extension
test/sql/ci-bindings.sql: test/expected/ci-install.out /tmp/extra-functions
	echo "\\\echo '$(shell \
		cat test/expected/ci-install.out \
		| grep -o '\bh3_\w*' \
		| sed -r 's/\bh3_//g' \
		| grep -v -x -F -f /tmp/extra-functions \
		| sort | uniq \
	)'" > $@

ci: test/sql/ci-install.sql test/expected/ci-install.out test/sql/ci-operators.sql test/expected/ci-operators.out test/sql/ci-bindings.sql test/expected/ci-bindings.out
.PHONY: ci format
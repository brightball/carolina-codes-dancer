# First-party Perl only. Never pass gitignored local/ to critic or tidy.
PERL_SOURCES := app.psgi bin/server $(wildcard lib/*.pm lib/*/*.pm lib/*/*/*.pm t/*.t scripts/*.pl)

export PATH := $(CURDIR)/local/bin:$(HOME)/.local/bin:$(PATH)
export PERL5LIB := $(CURDIR)/local/lib/perl5:$(PERL5LIB)

.PHONY: test perlcritic audit gitleaks perltidy check hooks

test:
	perl -Ilocal/lib/perl5 t/handler.t
	perl -Ilocal/lib/perl5 t/boot.t
	perl -Ilocal/lib/perl5 t/gate_wiring.t
	perl -Ilocal/lib/perl5 t/ci_prepared_tree.t
	perl -Ilocal/lib/perl5 t/readme_versions.t

perlcritic:
	perlcritic --profile .perlcriticrc $(PERL_SOURCES)

audit:
	cpan-audit --no-corelist --no-color --ascii --exclude-file cpan-audit-exclude.txt deps .

gitleaks:
	gitleaks detect --source . --verbose --no-banner

perltidy:
	perltidy --profile=.perltidyrc --assert-tidy $(PERL_SOURCES)

check: test perlcritic audit gitleaks perltidy

hooks:
	pre-commit install
	git config core.hooksPath .githooks

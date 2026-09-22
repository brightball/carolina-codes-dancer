#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/local/lib/perl5";
use lib "$FindBin::Bin/lib";
use CarolinaCodes::Dancer;

CarolinaCodes::Dancer::start_register_with_elixir()
    unless $ENV{HARNESS_ACTIVE} || $ENV{DANCER_TESTING};

CarolinaCodes::Dancer->to_app;

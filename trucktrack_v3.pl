#!/usr/bin/env perl

=head1 NAME

trucktrack.pl

=head1 DESCRIPTION

=head1 INSTALLATION

=cut

use strict;
use warnings FATAL => 'all';
use English '-no_match_vars';

use 5.32.1;
use Carp qw( croak confess );

use FindBin;
use local::lib "$FindBin::Bin/perl";
use lib "$FindBin::Bin/lib";

use TruckTrack::Term;

my $tt_term = TruckTrack::Term->new();

$SIG{INT} = sub { $tt_term->quit() };

$tt_term->main_menu();

#!/usr/bin/env perl

=head1 NAME

trucktrack.pl

=head1 DESCRIPTION

=head1 INSTALLATION

First install cpanm with your system package manager.

 apt install cpanminus

... or something like that.  Whatever it is in `yum`, not sure.
Or install L<App::cpanminus> with C<`cpan`>.

Next run C<`cpanm --installdeps --notest --local-lib ./perl .`>

Now run C<`./trucktrack.pl`>

=cut

use strict;
use warnings FATAL => 'all';
use English '-no_match_vars';

use 5.32.1;
use Carp qw( croak confess );

use FindBin;
use local::lib "$FindBin::Bin/perl";
use lib "$FindBin::Bin/lib";

use Cwd qw( abs_path );
use Text::CSV;
use YAML qw( LoadFile DumpFile Dump );
use LWP::Simple;
use Readonly;
use List::Util qw( sum );
use List::MoreUtils qw( mesh any );
use IO::Prompter;

Readonly my $sfbay_url => 'https://data.sfgov.org/api/views/rqzj-sfat/rows.csv';
Readonly my $datafile => "$FindBin::Bin/trucktrack.yml";

my $csv = Text::CSV->new({ binary => 1, auto_diag => 1 });

srand();

# read data from the YAML files
my $trucks = read_trucks();

# Update it with the latest info from the URL if requested, or if files were not there
update_trucks($trucks) if !scalar(keys(%{$trucks})) || scalar(grep { $_ eq '--update' } @ARGV);

main_menu($trucks);

=head1 Display functions

=head2 main_menu

=cut

sub main_menu {
    my ($trucks) = @_;

    my $choice = prompt 'Find a truck:', -menu => [
        'Search items',
        'Search company or truck name',
        'Search on street',
        'Search near street address',
        'Find rated trucks',
        'Find a new unrated truck',
        'Quit'
    ];

    (my $subname = lc $choice) =~ s/\s/_/g;

    my $location_id;
    eval "\$location_id = $subname(\$trucks)";
    croak "$EVAL_ERROR" if $EVAL_ERROR;

    display_details($trucks->{$location_id});

    my $want_to_rate = prompt "Do you want to rate this truck?" => -yn;
    rate_truck($trucks->{$location_id}) if $want_to_rate =~ /y/i;

    quit();
}

=head2 rate_truck

Rate the truck from 1 to 5, add to the average rating.

=cut

sub rate_truck {
    my ($truck) = @_;
    $truck->{ratings} //= [ ];
    say "You can rate a truck as many times as you want. Play fair!";
    my $rating = prompt 'Enter a number from 1 to 5:', -integer, -must => { 'be in range' => [1..5] };
    $rating = int($rating);
    push @{$truck->{ratings}}, $rating;
    my $current_rating = calculate_rating($truck, 'force recalc');
    say sprintf("The new rating is %.2f", $current_rating);
    say "Thanks for counting your rating!";
    return;
}

=head2 quit

Save the truck data to the datafile and exit the program.

=cut

sub quit {

    save_trucks($trucks);

    say "Goodbye!";
    exit(0);
}

=head2 display_details

=cut

sub display_details {
    my ($truck) = @_;

  # print Dump($truck);  # to be refined

    my $rating = calculate_rating($truck, 'force recalc') || 'not yet rated';

    say '=======================';
    say "Name:      $truck->{Applicant}";
    say "Rating:    $rating";
    say "Food:      $truck->{FoodItems}";
    say "Type:      $truck->{FacilityType}";
    say "Address:   $truck->{Address}";
    say "Loc descr: $truck->{LocationDescription}";
    say "Lat/Lon:   $truck->{Location}";
    say "Open:      ".($truck->{dayshours} || 'unknown hours');
    say "(locid):   $truck->{locationid}";
    say '';
}

=head2 choose_a_truck

From many location ids, choose one.

=cut

sub choose_a_truck {
    my (%p) = @_;
    my ($trucks, $location_ids) = @p{qw( trucks location_ids )};
    my $choice = prompt 'Choose a matching truck:', -menu => [
        map "$trucks->{$_}{Applicant} @ $trucks->{$_}{Address}\n\t$trucks->{$_}{FoodItems}\n\t(l=$_)",
            sort { $trucks->{$a}{Applicant} cmp $trucks->{$b}{Applicant} }
            @{$location_ids}
    ];
    my ($location_id) = $choice =~ m{ l=(\d+) }mxs;
    return $location_id;
}

=head1 Search functions

=head2 find_rated_trucks

=cut

sub find_rated_trucks {
    my ($trucks) = @_;

    say "Search for trucks in this rating range.";

    my $rating_min = prompt 'Enter a minimum number from 1 to 5:', -integer, -must => { 'be in range' => [1..5] };
    $rating_min = int($rating_min);

    my $rating_max = prompt 'Enter a maximum number from 1 to 5:', -integer, -must => { 'be in range' => [$rating_min..5] };
    $rating_max = int($rating_max);

    my @location_ids = grep {
        exists $trucks->{$_}{rating}
            && $trucks->{$_}{rating} >= $rating_min
            && $trucks->{$_}{rating} <= $rating_max
    } keys %{$trucks};

    return narrow_options(trucks => $trucks, location_ids => \@location_ids);
}

=head2 find_a_new_unrated_truck

Return a random truck that doesn't have any votes yet.

=cut

sub find_a_new_unrated_truck {
    my ($trucks) = @_;
    my @location_ids = grep !exists $trucks->{$_}{votes}, keys %{$trucks};
    say '';
    say "Try this one!";
    return $location_ids[int(rand(@location_ids))];
}

=head2 search_items

=cut

sub search_items {
    my ($trucks) = @_;
    my $search = prompt 'Enter an item, e.g. "burgers" or search string:';
    my @location_ids = grep $trucks->{$_}{FoodItems} =~ m{ \Q$search\E }mxsi, keys %{$trucks};
    return narrow_options(trucks => $trucks, location_ids => \@location_ids);
}

=head2 search_company_or_truck_name

=cut

sub search_company_or_truck_name {
    my ($trucks) = @_;
    my $search = prompt 'Enter a company or truck name or partial match:';
    my @location_ids = grep $trucks->{$_}{Applicant} =~ m{ \Q$search\E }mxsi, keys %{$trucks};
    return narrow_options(trucks => $trucks, location_ids => \@location_ids);
}

=head2 search_on_street 

=cut

sub search_on_street {
    my ($trucks) = @_;
    my $search = prompt 'Enter a street name or partial match:';
    my @location_ids = grep $trucks->{$_}{Address} =~ m{ \Q$search\E }mxsi, keys %{$trucks};
    return narrow_options(trucks => $trucks, location_ids => \@location_ids);
}

=head2 narrow_options

From no location id, many location ids, or one location id, decide what to do.

=cut

sub narrow_options {
    my (%p) = @_;
    my ($trucks, $location_ids) = @p{qw( trucks location_ids )};
    if (!@{$location_ids}) {
        say "Sorry, no trucks found.  Search again.";
        say '*'x20;
        main_menu($trucks);
    }
    elsif (@{$location_ids} > 1) {
        return choose_a_truck(%p);
    }
    else {
        return $location_ids->[0];
    }
}

=head2 search_near_street_address

=cut

sub search_near_street_address {
    die("Unimplemented.  Sorry, this is a toughie for the time available for this exercise.\n");
}


=head1 Data functions

=head2 read_trucks

Read the YAML datafile trucktrack.yml if it is there.

=cut

sub read_trucks {
    my $trucks = -e $datafile ? LoadFile($datafile) : { };
    return $trucks;
}

=head2 save_trucks

=cut

sub save_trucks {
    my ($trucks) = @_;
    DumpFile($datafile, $trucks);
    return;
}

=head2 update_trucks

Update the trucks data.

=cut

sub update_trucks {
    my ($trucks) = @_;

    say "updating trucks data from $sfbay_url...";

    # get and feed the data from SF
    my $csv_content = get($sfbay_url) || croak "cannot get CSV content";
    my @csv_lines = $csv_content =~ m{ ^ (.*?) (?: \r? \n) }mxsg;

    my %dup_locid_check;

    my @csv_keys;
    for (my $i = 0; $i <= $#csv_lines; $i++) {
        my $line = $csv_lines[$i];
        $csv->parse($line) || croak "bad input on line $i: ".$csv->error_input;
        if (!@csv_keys) {
            @csv_keys = $csv->fields();
            next;
        }
        my @csv_fields = $csv->fields();
        croak "doublebad input line $i: ".$csv->error_input if !@csv_fields;
        my %csv_data = mesh @csv_keys, @csv_fields;
    
        # some sanity checks for bad data in the source
        next if any { !$csv_data{$_} } qw( block lot );

        my $locationid = $csv_data{locationid};

        # sanity check for duplicate location id
        if (exists $dup_locid_check{$locationid}
            && $dup_locid_check{$locationid}{LocationDescription} ne $csv_data{LocationDescription}
            ) {
            croak "dup locationid with different details:".Dump($dup_locid_check{$locationid}, \%csv_data, $line);
        }
        $dup_locid_check{$locationid} = \%csv_data;

        $csv_data{Status} = 'APPROVED' if $csv_data{Status} eq 'ISSUED'; # probably equivalent?

        if ($csv_data{Status} ne 'APPROVED') {
            # we don't care about any that do not currently operate
            delete $trucks->{$locationid};
        }
        else {
            # update the data, but don't override anyone's votes
            @{ $trucks->{$locationid} }{@csv_keys} = @csv_data{@csv_keys};
        }
    
        #warn "=============\n$line\n".Dump(\%csv_data);
    }
    return;
}

=head2 calculate_rating

Pass optional flag to force recalculation from ratings entries.

Returns undef if cannot be calculated.

=cut

sub calculate_rating {
    my ($truck, $force_recalc) = @_;
    return $truck->{rating} if exists $truck->{rating} && !$force_recalc;
    my @ratings = @{ $truck->{ratings} // [ ] };
    if (scalar(@ratings)) {
        my $rating = sprintf("%.2f", (sum @ratings) / @ratings) + 0;
        $truck->{rating} = $rating;
        return $rating;
    }
    else {
        return undef;
    }
}

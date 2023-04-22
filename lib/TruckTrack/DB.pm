=head1 NAME

TruckTrack::DB

=head1 DESCRIPTION

Caching data file, fetch methods, etc.  for the food truck data source.

=cut

package TruckTrack::DB;

use strict;
use warnings FATAL => 'all';
use English '-no_match_vars';

use 5.32.1;
use Carp qw( croak confess );

use File::Basename;
use YAML qw( LoadFile DumpFile Dump );
use Readonly;
use Text::CSV;
use LWP::Simple;
use Cwd qw( abs_path );
use List::Util qw( sum );
use List::MoreUtils qw( mesh any );
use GIS::Distance;
use Geo::Coder::OSM;

use TruckTrack::Truck;

srand();

Readonly my $sfbay_url => 'https://data.sfgov.org/api/views/rqzj-sfat/rows.csv';

my $csv = Text::CSV->new({ binary => 1, auto_diag => 1 });
my $geo = Geo::Coder::OSM->new();
my $gis = GIS::Distance->new();

=head1 METHODS

=head2 new

 my $db = TruckTrack::DB->new(datafile => "$FindBin::Bin/truckdata.yml");

It figures you want to use it, so it goes ahead and populates
the data.

If C<$ENV{trucktrack_update}> is set, it updates the data even if
it already finds a cached dataset file.

You have to specify a data file, so it can save ratings.
The above value is the default.  Or set C<$ENV{trucktrack_datadir}>.

=cut

sub new {
    my ($class, %args) = @_;

    my $datafile = $args{datafile};
    $datafile //= "$ENV{trucktrack_datadir}/truckdata.yml" if $ENV{trucktrack_datadir};
    $datafile //= "$FindBin::Bin/truckdata.yml";

    my $self = { datafile => $datafile };

    # check data directory permissions
    my $datadir = dirname($self->{datafile});
    croak "Cannot read and write to data directory $datadir"
        if !(-e $datadir && -r _ && -w _);

    bless $self, $class;
    $self->trucks();
    return $self;
}

=head2 trucks

 my $trucks = $db->trucks();

If the database has already been downloaded and put into a YAML file,
populate it from that.

Otherwise, load it from the sfgov.org URL.

=cut

sub trucks {
    my ($self) = @_;

    my $trucks = $self->{trucks};
    return $trucks if scalar(keys(%{$trucks})) && !$ENV{trucktrack_update};

    if (-e $self->{datafile}) {
        $trucks = LoadFile($self->{datafile});
        bless $_, 'TruckTrack::Truck' for values %{$trucks};
        $self->{trucks} = $trucks;
        return $trucks if !$ENV{trucktrack_udpate};
    }

    warn "updating trucks data from $sfbay_url...\n";

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
        my $dupcheck = $dup_locid_check{$locationid};
        if  (   defined $dupcheck
            &&  $dupcheck->{LocationDescription} ne $csv_data{LocationDescription}
            ) {
            croak "dup locationid with different details:"
                .Dump($dupcheck, \%csv_data, $line);
        }
        $dup_locid_check{$locationid} = \%csv_data;

        # 'ISSUED' and 'APPROVED' are probably equivalent?
        $csv_data{Status} = 'APPROVED' if $csv_data{Status} eq 'ISSUED';

        if ($csv_data{Status} ne 'APPROVED') {
            # we don't care about any that do not currently operate
            delete $trucks->{$locationid};
        }
        elsif (!exists $trucks->{$locationid}) {
            # create the truck object if it does not exist
            $trucks->{$locationid} = TruckTrack::Truck->new(%csv_data);
        }
        else {
            # update the data, but don't override anyone's votes
            @{ $trucks->{$locationid} }{@csv_keys} = @csv_data{@csv_keys};
        }
    
        #warn "=============\n$line\n".Dump(\%csv_data);
    }

    $self->{trucks} = $trucks;

    my @undef_locids = grep { !defined $trucks->{$_} } keys %{$trucks};
    #croak "WTF undefined trucks\n".Dump(\@undef_locids) if @undef_locids;

    $self->save();
    return;
}

=head2 save

=cut

sub save {
    my ($self) = @_;
    my $datafile = $self->{datafile};
    DumpFile($datafile, $self->{trucks});
    return;
}

=head2 search

Slightly inefficient, this searches the whole list of trucks each time.

=cut

sub search {
    my ($self, %p) = @_;
    my $search = $self->{search} = $p{search} //= { };
    $self->{results} = { %{$self->{trucks}} };
    for my $name (keys %{$search}) {
        my $method = "search_$name";
        $self->$method( $search->{$name}{criteria} );
    }
    return $self->{results};
}

sub search_items {
    my ($self, $criteria) = @_;
    return $self->_field_search(criteria => $criteria, field => 'FoodItems');
}

sub search_company {
    my ($self, $criteria) = @_;
    return $self->_field_search(criteria => $criteria, field => 'Applicant');
}

sub search_street {
    my ($self, $criteria) = @_;
    return $self->_field_search(criteria => $criteria, field => 'Address');
}

sub _field_search {
    my ($self, %p) = @_;
    my ($criteria, $field) = @p{qw( criteria field )};
    return if !defined $criteria || $criteria eq '';
    croak 'bad params - no field name to search' if !$field;

    my $results = $self->{results};
    my $trucks  = $self->{trucks};

    for my $locationid (keys %{$results}) {
        my $match = $trucks->{$locationid}{$field} =~ m{ \Q$criteria\E }mxsi;
        delete $results->{$locationid} if !$match;
    }

    return;
}

sub search_rating {
    my ($self, $criteria) = @_;
    return if !defined $criteria || $criteria eq '';

    my ($min) = $criteria =~ m{ min=(\d+) }mxs;
    my ($max) = $criteria =~ m{ max=(\d+) }mxs;
    return if !defined $min || !defined $max;
    croak "min exceeds max" if $min > $max;

    my $results = $self->{results};
    my $trucks  = $self->{trucks};

    for my $locationid (keys %{$results}) {
        my $match = exists $trucks->{$locationid}{rating}
            && $trucks->{$locationid}{rating} >= $min
            && $trucks->{$locationid}{rating} <= $max;
        delete $results->{$locationid} if !$match;
    }

    return;
}

sub search_locationid {
    my ($self, $locationid) = @_;

    my $trucks = $self->{trucks};
    $self->{results} = { $locationid => $trucks->{$locationid} };
    return;
}

sub search_distance {
    my ($self, $criteria) = @_;
    return if !defined $criteria || $criteria eq '';

    my ($miles, $address) = $criteria
        =~ m{ \A (.*) \s+ miles? \s+ from \s+ (.*) \z }mxs;

    my ($lat, $lon) = $self->_get_lat_lon($address);
    if (!defined $lat || !defined $lon) {
        warn "Could not identify lat/lon of search address.\n";
        return;
    }

  # warn "searching for addresses within $miles miles of $address\n";

    my $results = $self->{results};
    my $trucks  = $self->{trucks};

    my @matches;
    my $number = scalar keys %{$results};
    my $i = 0;
    for my $locationid (keys %{$results}) {
      # warn sprintf("searching %i of %i results\n", ++$i, $number);
        my $truck = $trucks->{$locationid};
        my $distance = $gis->distance(
            $lat, $lon,
            @{$truck}{qw( Latitude Longitude )}, 
        );
      # warn sprintf("result is %f miles\n", $distance->miles);
        delete $results->{$locationid} if $distance->miles > $miles;
    }

    return;
}

sub search_unrated {
    my ($self, $criteria) = @_;
    return if !defined $criteria || $criteria eq '';
    my $trucks = $self->{trucks};
    my @all_locids = keys %{$trucks};
    my @locationids = grep { !exists $trucks->{$_}{votes} } keys %{$trucks};
    my $locationid = $locationids[ int( rand(@locationids) ) ];
    $self->{results} = { $locationid => $trucks->{$locationid} };
    return;
}

sub _get_lat_lon {
    my ($self, $address) = @_;

    my $location = $geo->geocode(location => $address);
    my $response = $geo->response();
    warn "OpenStreetMaps Error: ".$response->status_line."\n"
        if !$response->is_success;

  # warn Dump($location);

    my ($lat, $lon) = @{$location}{qw(lat lon)};

    if (!defined $lat || !defined $lon) {
        warn "Cannot find location for requested address.\n";
        return;
    }

    return ($lat, $lon);
}

1;

#
#
#
#=head2 find_a_new_unrated_truck
#
#Return a random truck that doesn't have any votes yet.
#
#=cut
#
#sub find_a_new_unrated_truck {
#    my ($trucks) = @_;
#    my @location_ids = grep !exists $trucks->{$_}{votes}, keys %{$trucks};
#    say '';
#    say "Try this one!";
#    return $location_ids[int(rand(@location_ids))];
#}
#
#
#
#
1;

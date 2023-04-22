=head1 NAME

TruckTrack::Truck

=head1 DESCRIPTION

Object representing a truck, with its data.

Created by L<TruckTrack::DB>.

It seemed like Moose or Moo would be over-engineering for this exercise.

=cut

package TruckTrack::Truck;

use strict;
use warnings FATAL => 'all';
use English '-no_match_vars';
use 5.32.1;
use Carp qw( croak confess );

use List::Util qw( sum );

use overload q{""} => 'display_text';

sub new {
    my ($class, %args) = @_;
    my $self = { %args };
    bless $self, $class;
    return $self;
}

sub display_text {
    my ($self) = @_;
    my $rating = $self->calculate_rating(force => 1) || 'not yet rated';

    say $_ for
        '=======================',
        "Name:      $self->{Applicant}",
        "Rating:    $rating",
        "Food:      $self->{FoodItems}",
        "Type:      $self->{FacilityType}",
        "Address:   $self->{Address}",
        "Loc descr: $self->{LocationDescription}",
        "Lat/Lon:   $self->{Location}",
        "Open:      ".($self->{dayshours} || 'unknown hours'),
        "(locid):   $self->{locationid}",
        '',
        ;
}

sub display_short_text {
    my ($self) = @_;
    return "$self->{Applicant} @ $self->{Address}\n"
            ."\t$self->{FoodItems}\n"
            ."\t(l=$_)"
            ;
}

sub calculate_rating {
    my ($self, %p) = @_;
    return $self->{rating} if exists $self->{rating} && !$p{force_recalc};
    my @ratings = @{ $self->{ratings} // [ ] };
    if (my $rating_count = scalar(@ratings)) {
        my $rating = sprintf("%.2f", (sum @ratings) / $rating_count);
        $self->{rating} = $rating;
        return $rating;
    }
    else {
        return undef;
    }

}

1;

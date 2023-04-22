=head1 NAME

TruckTrack::Term

=head1 DESCRIPTION

The command line interface for TruckTrack, used by the script.

=cut

package TruckTrack::Term;

use strict;
use warnings FATAL => 'all';
use English '-no_match_vars';

use 5.32.1;
use Carp qw( croak confess );

use List::Util qw( max );
use IO::Prompter;
use Lingua::EN::Inflect qw( PL );
use YAML qw( Dump );

use TruckTrack::DB;

=head1 METHODS

=head2 new

 my $tt_term = TruckTrack::Term->new();

You can pass all the same arguments as you can to L<TruckTrack::DB>
and they will be passed through.

=cut

sub new {
    my ($class, %p) = @_;

    my $self = {
        db      => TruckTrack::DB->new(%p),
        trucks  => { },
    };
    bless $self, $class;

    return $self;
}


=head1 Display functions

=head2 main_menu

=cut

sub main_menu {
    my ($self) = @_;
    croak "Find a hobby." if ++$self->{main_menu_calls} == 1024;

    say '';
    my $menu = $self->_main_menu_prompts;
    my $choice = prompt '-v', 'I can haz fudtrukz?', -menu => $menu;

    my ($method) = $choice =~ m{ \A (\w+) }mxs;
    croak("no method found from choice='$choice'") if !$method;
    $method =~ s{ \s+ }{_}mxsg;
    $method = '_' . lc $method;

    my $locationid = $self->$method();

    my $db = $self->{db};

    #my $truck = $db->find_truck(locationid => $locationid);
    my $trucks = $self->{trucks} = $db->search(search => $self->{search});

    my $count = scalar keys %{$trucks};
    if (!$count) {
        say "O noes! Hungrys! Your search found zero trucks.";
    }
    elsif ($count == 1) {
        my ($truck) = values %{$trucks};
        say $truck;
        my $want_to_rate = prompt '-v', "Do you want to rate this truck?" => -yn;
        $self->rate_truck($truck) if $want_to_rate =~ /y/i;
        say "OK!";
        $self->_clear();
    }
    
    $self->main_menu;

    quit();
}

=head1 Private functions

Moose/Moo was over-engineering for this exercise.
Don't use these methods from the caller.  Just call C<main_menu()>.

=head2 _clear

=cut

sub _clear {
    my ($self) = @_;

    # clear all criteria
    $_->{criteria} = q{} for values %{$self->{search}};

    # clear trucks from result list
    delete $self->{trucks};
    
    return;
}

=head2 _main_menu_prompts

=cut

sub _main_menu_prompts {
    my ($self) = @_;

    # assemble the menu and also the internal named reference to menu items
    my $search = $self->{search} //= { };
    my $search_items = $self->{search_items} //= [ ];

    my @names = qw( items company street distance rating unrated );
    for (my $i = 0; $i <= $#names; $i++) {
        my $name = $names[$i];
        my $item = $search->{$name} //= {
            text     => ucfirst($name),
            criteria => q{},
        };
        $search_items->[$i] //= $item;
    }

    my $field_len_1 = max map length($_->{text}),     @{$search_items};
    my $field_len_2 = max map length($_->{criteria}), @{$search_items};

    my $menu_sprintf = '%-' . $field_len_1 . 's   %' . $field_len_2 . 's';

    #warn "KIRK:\n".Dump($self->{search});

    # print the menu nicely with any criteria that have been saved

    my $count = scalar(keys %{$self->{trucks}});
    if ($count) {
        say sprintf("Your search returned %i %s.", $count, PL("truck", $count));
        if ($count > 1) {
            say "Narrow options by adding search criteria, or choose from list.";
        }
    }
        

    return [
        (
            map sprintf( $menu_sprintf, $_->{text}, ($_->{criteria} ? "[$_->{criteria}]" : '') ),
            @{$search_items}
        ),
        ($count
            ? sprintf('Choose from list of %i %s', $count, PL('truck', $count))
            : ()
        ),
        'Clear',
        'Quit',
    ];
}



sub _items {
    my ($self) = @_;
    my $search_string = prompt -v => 'Enter search terms, like "burgers":';
    #warn "CHEKOV: '$search_string'\n";
    #warn "UHURA:\n".Dump($self->{search});
    $self->{search}{items}{criteria} = $search_string;  # to search FoodItems
    #warn "SPOCK:\n".Dump($self->{search});
    #warn "MCCOY:\n".Dump($self->{search_items});
    return;
}

sub _company {
    my ($self) = @_;
    my $search = prompt -v => 'Enter a company or truck name or partial match:';
    $self->{search}{company}{criteria} = $search;
    return;
}

sub _street {
    my ($self) = @_;
    my $search = prompt -v => 'Enter a street name:';
    $self->{search}{street}{criteria} = $search;
    return;
}

sub _distance {
    my ($self) = @_;
    my $address = prompt -v => 'Enter an address to search near:';
    my $range   = prompt '-v', -num => 'Enter a distance, in miles, e.g. "0.25":';
    $self->{search}{distance}{criteria} = sprintf(
        "%.2f %s from %s", $range, PL('mile', $range), $address
    );
    return;
}

sub _rating {
    my ($self) = @_;

    if ($self->{search}{unrated}{criteria}) {
        say "Incompatible search: already looking for an unrated truck.";
        return;
    }
    
    my $min = int(prompt
        '-v',
        'Enter a minimum number from 1 to 5:',
        '-integer',
        -must => { 'be in range' => [1..5] }
    );

    my $max = int(prompt
        '-v',
        'Enter a maximum number from 1 to 5:',
        '-integer',
        -must => { 'be in range' => [$min..5] }
    );

    $self->{search}{rating}{criteria} = "min=$min max=$max";
    return;
}

sub _unrated {
    my ($self) = @_;

    say "This will find a random unrated truck.";

    $self->_clear();

    $self->{search}{unrated}{criteria} = 'find random unrated truck';
    return;
}

sub _choose {
    my ($self) = @_;
    my $trucks = $self->{trucks};
    my $choice = prompt 'Choose a matching truck:', -menu => [
        map $trucks->{$_}->display_short_text(),
        sort { $trucks->{$a}{Applicant} cmp $trucks->{$b}{Applicant} }
        keys %{$trucks}
    ];
    my ($locationid) = $choice =~ m{ l=(\d+) }mxs;
    $self->{search}{locationid}{criteria} = $locationid;
    return;
}


=head2 rate_truck

Rate the truck from 1 to 5, add to the average rating.

=cut

sub rate_truck {
    my ($self, $truck) = @_;
    $truck->{ratings} //= [ ];
    say "You can rate a truck as many times as you want. Play fair!";
    my $rating = int(prompt
        '-v',
        'Enter a number from 1 to 5:',
        -integer,
        -must => { 'be in range' => [1..5] }
    );
    push @{$truck->{ratings}}, $rating;
    my $current_rating = $truck->calculate_rating(force_recalc => 1);
    say sprintf("The new rating is %.2f", $current_rating);
    say "Thanks for counting your rating!";
    $self->{db}->save();
    return;
}

=head2 quit

Save the truck data to the datafile and exit the program.

=cut

sub _quit { shift->quit() }
sub quit {
    my ($self) = @_;

    $self->{db}->save();

    say "Goodbye!";
    exit(0);
}


1;

# See bottom of file for license and copyright information
use v5.16;
use strict;
use warnings;

package DBIQueryPluginTests;

use strict;
use warnings;

use FoswikiFnTestCase;
our @ISA = qw( FoswikiFnTestCase );

use Foswiki;
use Foswiki::Func;
use CGI;
use File::Temp;
use File::Copy;
use Data::Dumper;

sub new {
    my $self = shift()->SUPER::new(@_);
    return $self;
}

# Set up the test fixture
sub set_up {
    my $this = shift;

    say STDERR "THIS: $this";

    $this->SUPER::set_up();

    say STDERR "set_up done";

    my $temp_dir = $this->{db_test_dir}->dirname;

=pod
    $this->assert(
        copy($this->{msg_board_sqlite}, $temp_dir),
        "Copy of $this->{msg_board_sqlite} to $temp_dir: $!"
    );
=cut
}

sub tear_down {
    my $this = shift;

    say STDERR "tear down";

    delete $this->{db_test_dir};

    $this->SUPER::tear_down();
}

sub loadExtraConfig {
    my $this = shift;

    say STDERR "SUPER::loadExtraConfig";

    $this->SUPER::loadExtraConfig();
    say STDERR "loadExtraConfig";

    $this->{db_test_dir} = File::Temp->newdir('dbiqp_tempXXXX');
    $this->{db_msgb_file} = 'message_board_test.sqlite';
    $this->{do_test_topic} = "Do" . $this->{test_topic};

    $Foswiki::cfg{Plugins}{DBIQueryPlugin}{Enabled} = 1;
    $Foswiki::cfg{Plugins}{DBIQueryPlugin}{Debug} = 1;
    $Foswiki::cfg{Plugins}{DBIQueryPlugin}{ConsoleDebug} = 1;
    $Foswiki::cfg{PluginsOrder} = 'TWikiCompatibilityPlugin,DBIQueryPlugin,SpreadSheetPlugin,SlideShowPlugin';

    $Foswiki::cfg{Contrib}{DatabaseContrib}{dieOnFailure}   = 0;
    $Foswiki::cfg{Extensions}{DatabaseContrib}{connections} = {
        mock_connection => {
            driver            => 'Mock',
            database          => 'sample_db',
            codepage          => 'utf8',
            user              => 'unmapped_user',
            password          => 'unmapped_password',
            driver_attributes => {
                mock_unicode   => 1,
                some_attribute => 'YES',
            },
            allow_do => {
                "$this->{test_web}.$this->{do_test_topic}" => [qw(ScumBag)],
            },
            allow_query => {
                "$this->{test_web}.$this->{test_topic}" => [qw(ScumBag)],
            },
            usermap => {
                DummyGroup => {
                    user     => 'dummy_map_user',
                    password => 'dummy_map_password',
                },
            },

            # host => 'localhost',
        },
        sqlite_connection => {
            driver            => 'SQLite',
            database          => $this->{db_test_dir}->dirname . "/db.sqlite",
            codepage          => 'utf8',
            driver_attributes => { sqlite_unicode => 1, },
        },
        msg_board_sqlite => {
            driver            => 'SQLite',
            database          => $this->{db_test_dir}->dirname . "/" . $this->{db_msgb_file},
            codepage          => 'utf8',
            driver_attributes => { sqlite_unicode => 1, },
        },
    };
}

sub test_self {
    my $this = shift;
}

sub test_query
{
    my $this = shift;
    say STDERR "test_query";

    my $query = Unit::Request->new();
    say STDERR "Before new session: ", $this->{test_web}, ".", $this->{test_topic};
    my $session = $this->createNewFoswikiSession( 'ScumBag', $query );
    #my $session = $this->{session};
    say STDERR "After new session: ", $this->{test_web}, ".", $this->{test_topic};

    my $test_topic = Foswiki::Meta->new( $session, $this->{test_web}, $this->{test_topic} );

    say STDERR Dumper($Foswiki::cfg{Extensions}{DatabaseContrib}{connections});

    my $q_topic = <<TSRC;
    %DBI_VERSION%

%DBI_QUERY{"mock_connection"}%
SELECT col1, col2 FROM test_table
.header
|*Col1*|*Col2*|
.body
|%col1%|%col2%|
%DBI_QUERY%
TSRC

    say STDERR "1. this topic object: ", $session->{user}, "@", $test_topic->web, ".", $test_topic->topic;
    say STDERR "expandMacros";
    my $q_out = $test_topic->expandMacros($q_topic);
    say STDERR "Q_OUT:\n", $q_out;

    say STDERR "renderTML";
    my $html = $test_topic->renderTML($q_out);
    say STDERR "HTML:\n", $html;
}

1;
__END__
Foswiki - The Free and Open Source Wiki, http://foswiki.org/

Copyright (C) 2008-%$CREATEDYEAR% Foswiki Contributors. Foswiki Contributors
are listed in the AUTHORS file in the root of this distribution.
NOTE: Please extend that file, not this notice.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version. For
more details read LICENSE in the root of this distribution.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

As per the GPL, removal of this notice is prohibited.

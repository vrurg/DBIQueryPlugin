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

    #say STDERR "THIS: $this";

    $this->SUPER::set_up();

    #say STDERR "set_up done";

    my $temp_dir = $this->{db_test_dir}->dirname;

    $this->assert(
        Foswiki::Func::addUserToGroup(
            $this->{session}{user}, 'AdminGroup', 1
        ),
        "Failed to make $this->{session}{user} a new admin"
    );
    $this->assert( Foswiki::Func::addUserToGroup( 'ScumBag', 'AdminGroup', 0 ),
        'Failed to make ScumBag a new admin' );

=pod
    $this->assert(
        copy($this->{msg_board_sqlite}, $temp_dir),
        "Copy of $this->{msg_board_sqlite} to $temp_dir: $!"
    );
=cut

}

sub tear_down {
    my $this = shift;

    #say STDERR "tear down";

    delete $this->{db_test_dir};

    $this->SUPER::tear_down();
}

sub loadExtraConfig {
    my $this = shift;

    #say STDERR "SUPER::loadExtraConfig";

    $this->SUPER::loadExtraConfig();

    #say STDERR "loadExtraConfig";

    $this->{db_test_dir}   = File::Temp->newdir('dbiqp_tempXXXX');
    $this->{db_msgb_file}  = 'message_board_test.sqlite';
    $this->{do_test_topic} = "Do" . $this->{test_topic};

    $Foswiki::cfg{Plugins}{DBIQueryPlugin}{Enabled}      = 1;
    $Foswiki::cfg{Plugins}{DBIQueryPlugin}{Debug}        = 0;
    $Foswiki::cfg{Plugins}{DBIQueryPlugin}{ConsoleDebug} = 0;
    $Foswiki::cfg{PluginsOrder} =
'TWikiCompatibilityPlugin,DBIQueryPlugin,SpreadSheetPlugin,SlideShowPlugin';

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
                "$this->{test_web}.$this->{do_test_topic}" => [qw(AdminGroup)],
            },
            allow_query => {
                "$this->{test_web}.$this->{test_topic}" =>
                  [qw(TestGroup AdminGroup)],
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
            driver   => 'SQLite',
            database => $this->{db_test_dir}->dirname . "/"
              . $this->{db_msgb_file},
            codepage          => 'utf8',
            driver_attributes => { sqlite_unicode => 1, },
        },
    };
}

sub expand_source {
    my $tt = $_[0]->{test_topicObject};
    return $tt->renderTML( $tt->expandMacros( $_[1] ) );
}

sub test_self {
    my $this = shift;
}

sub test_version {
    my $this       = shift;
    my $test_topic = $this->{test_topicObject};

    my $v_topic = '%DBI_VERSION%';

    my $v_html = $this->expand_source($v_topic);
    $this->assert_html_equals(
        $v_html,
        "$Foswiki::Plugins::DBIQueryPlugin::VERSION",
        "\%DBI_VERSION\% output mismatch"
    );
}

sub test_query {
    my $this = shift;

#my $request = Unit::Request->new();
#say STDERR "Before new session: ", $this->{test_web}, ".", $this->{test_topic};
#my $session = $this->createNewFoswikiSession( 'ScumBag', $request );
#say STDERR "After new session: ", $this->{test_web}, ".", $this->{test_topic};

#my $test_topic = Foswiki::Meta->new( $session, $this->{test_web}, $this->{test_topic} );

    #say STDERR Dumper($Foswiki::cfg{Extensions}{DatabaseContrib}{connections});

    my $test_topic = $this->{test_topicObject};

    my $q_topic = <<TSRC;
%DBI_QUERY{"mock_connection"}%
SELECT col1, col2 FROM test_table
.header
|*Col1*|*Col2*|
.body
|%col1%|%col2%|
%DBI_QUERY%
TSRC

#say STDERR "1. this topic object: ", $session->{user}, "@", $test_topic->web, ".", $test_topic->topic;
#say STDERR "expandMacros";
    my $q_html = $test_topic->renderTML( $test_topic->expandMacros($q_topic) );

    #say STDERR "HTML:\n", $q_html;

    $this->assert_html_equals( $q_html,
        <<QHTML, "\%DBI_QUERY\% output mismatch" );
<nop>
<table border="1" class="foswikiTable" rules="none">
<thead>
    <tr class="foswikiTableOdd foswikiTableRowdataBgSorted0 foswikiTableRowdataBg0">
        <th class="foswikiTableCol0 foswikiFirstCol foswikiLast"> <a href="/bin//TemporaryDBIQueryPluginTestsTestWebDBIQueryPluginTests/TestTopicDBIQueryPluginTests?sortcol=0;table=1;up=0#sorted_table" rel="nofollow" title="Sort by this column">Col1</a> </th>
        <th class="foswikiTableCol1 foswikiLastCol foswikiLast"> <a href="/bin//TemporaryDBIQueryPluginTestsTestWebDBIQueryPluginTests/TestTopicDBIQueryPluginTests?sortcol=1;table=1;up=0#sorted_table" rel="nofollow" title="Sort by this column">Col2</a> </th>
    </tr>
</thead>
<tbody>
    <tr style="display:none;">
        <td></td>
    </tr>
</tbody>
</table>
QHTML
}

sub test_code {
    my $this = shift;

    my $c_topic = <<TSRC;
%DBI_CODE{"script"}%
print 'It works!';
%DBI_CODE%
TSRC

    my $c_html = $this->expand_source($c_topic);

    #say STDERR "c_html: $c_html";
    $this->assert_html_equals( $c_html,
        <<CHTML, "\%DBI_CODE\% output mismatch" );
<table width="100%" border="0" cellspacing="5px">
    <tr>
        <td nowrap> <strong>Script name</strong> </td>
        <td> <code>script</code> </td>
    </tr>
    <tr valign="top">
        <td nowrap> <strong>Script code</strong> </td>
        <td> <pre>
            print 'It works!';
        </pre> </td>
    </tr>
</table>
CHTML
}

sub test_subquery {
    my $this = shift;

    my $s_topic = <<TSRC;
%DBI_CALL{"test_subquery"}%
%DBI_QUERY{"mock_connection" subquery="test_subquery"}%
SELECT f1, f2 FROM test_table
.header
|*First Column*|*Second Column*|
.body
|%f1%|%f2%|
%DBI_QUERY%
TSRC

    my $s_html = $this->expand_source($s_topic);

    #say STDERR "s_html: $s_html";

    $this->assert_html_equals( $s_html,
        <<SHTML, "\%DBI_CALL\% output mismatch" );
<nop>
<table border="1" class="foswikiTable" rules="none">
    <thead>
        <tr class="foswikiTableOdd foswikiTableRowdataBgSorted0 foswikiTableRowdataBg0">
            <th class="foswikiTableCol0 foswikiFirstCol foswikiLast"> <a href="/bin//TemporaryDBIQueryPluginTestsTestWebDBIQueryPluginTests/TestTopicDBIQueryPluginTests?sortcol=0;table=1;up=0#sorted_table" rel="nofollow" title="Sort by this column">First Column</a> </th>
            <th class="foswikiTableCol1 foswikiLastCol foswikiLast"> <a href="/bin//TemporaryDBIQueryPluginTestsTestWebDBIQueryPluginTests/TestTopicDBIQueryPluginTests?sortcol=1;table=1;up=0#sorted_table" rel="nofollow" title="Sort by this column">Second Column</a> </th>
        </tr>
    </thead>
    <tbody>
        <tr style="display:none;">
            <td></td>
        </tr>
    </tbody>
</table>
SHTML
}

sub test_do {
    my $this = shift;

    my $d_topic = <<TSRC;
%DBI_DO{"mock_connection"}%
\$rc .= "Test ok!";
%DBI_DO%
TSRC

    my $d_html = $this->expand_source($d_topic);
    say STDERR $d_html;

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

# See bottom of file for default license and copyright information

package Foswiki::Plugins::DBIQueryPlugin;

# Always use strict to enforce variable scoping
use strict;
use warnings;
use v5.10;

use Foswiki::Func    ();    # The plugins API
use Foswiki::Plugins ();    # For the API version
use DBI;
use Error qw(:try);
use CGI qw(:html2);
use Carp qw(longmess);
use Foswiki::Contrib::DatabaseContrib qw(:all);

# $VERSION is referred to by Foswiki, and is the only global variable that
# *must* exist in this package. For best compatibility, the simple quoted decimal
# version '1.00' is preferred over the triplet form 'v1.0.0'.

# For triplet format, The v prefix is required, along with "use version".
# These statements MUST be on the same line.
#  use version; our $VERSION = 'v1.2.3_001';
# See "perldoc version" for more information on version strings.
#
# Note:  Alpha versions compare as numerically lower than the non-alpha version
# so the versions in ascending order are:
#   v1.2.1_001 -> v1.2.2 -> v1.2.2_001 -> v1.2.3
#   1.21_001 -> 1.22 -> 1.22_001 -> 1.23
#
our $VERSION = '1.05';

# $RELEASE is used in the "Find More Extensions" automation in configure.
# It is a manually maintained string used to identify functionality steps.
# You can use any of the following formats:
# tuple   - a sequence of integers separated by . e.g. 1.2.3. The numbers
#           usually refer to major.minor.patch release or similar. You can
#           use as many numbers as you like e.g. '1' or '1.2.3.4.5'.
# isodate - a date in ISO8601 format e.g. 2009-08-07
# date    - a date in 1 Jun 2009 format. Three letter English month names only.
# Note: it's important that this string is exactly the same in the extension
# topic - if you use %$RELEASE% with BuildContrib this is done automatically.
# It is preferred to keep this compatible with $VERSION. At some future
# date, Foswiki will deprecate RELEASE and use the VERSION string.
#
our $RELEASE = '15 Sep 2015';

# One line description of the module
our $SHORTDESCRIPTION =
'This plugin is intended to provide TWiki with ability to make complex database requests using DBI Perl module.';

# You must set $NO_PREFS_IN_TOPIC to 0 if you want your plugin to use
# preferences set in the plugin topic. This is required for compatibility
# with older plugins, but imposes a significant performance penalty, and
# is not recommended. Instead, leave $NO_PREFS_IN_TOPIC at 1 and use
# =$Foswiki::cfg= entries, or if you want the users
# to be able to change settings, then use standard Foswiki preferences that
# can be defined in your %USERSWEB%.%LOCALSITEPREFS% and overridden at the web
# and topic level.
#
# %SYSTEMWEB%.DevelopingPlugins has details of how to define =$Foswiki::cfg=
# entries so they can be used with =configure=.
our $NO_PREFS_IN_TOPIC = 1;

my ( $topic, $web, $user, $installWeb, %queries, %subquery_map );

sub message_prefix {
    my @call = caller(2);
    my $line = ( caller(1) )[2];
    return
        "- "
      . $call[3]
      . (    defined $web
          && defined $topic ? "( $web.$topic )" : "( *uninitialized* )" )
      . "\:$line ";
}

sub warning(@) {
    return Foswiki::Func::writeWarning( message_prefix() . join( "", @_ ) );
}

sub dprint(@) {
    return unless $Foswiki::cfg{Plugins}{DBIQueryPlugin}{Debug};
    say STDERR message_prefix() . join( "", @_ )
      if $Foswiki::cfg{Plugins}{DBIQueryPlugin}{ConsoleDebug};
    return Foswiki::Func::writeDebug( message_prefix() . join( "", @_ ) );
}

sub wikiErrMsg {
    return
        "<strong>\%RED\%ERROR:\n<pre>"
      . join( "", @_ )
      . "\n</pre>\%ENDCOLOR\%</strong>";
}

=begin TML

---++ nl2br($string) -> $tml_string
   * =$string= - a chunk of text data
   * =$tml_string= - text in Wiki TML format

Replaces all newlins with =%<nop>BR%= thus preventing an arbitrary text data mangling
Wiki formatting. For instance, it allows inserting multiline texts into a table cell.

=cut

sub nl2br {
    $_[0] =~ s/\r?\n/\%BR\%/g;
    return $_[0];
}

=begin TML

---++ protectValue($string) -> $string
   *=$string= - an arbitrary string

Transforms =$string= into a format protected from excessive processing by
the Wiki engine.

NB. Shall become obsoleted as soon as the plugin rewritted to be based
totally on =registerTagHandler()= interface.

=cut

sub protectValue {
    my $val = shift;
    dprint "Before protecting: $val\n";
    $val =~ s/(.)/\.$1/gs;
    $val =~ s/\\(n|r)/\\\\$1/gs;
    $val =~ s/\n/\\n/gs;
    $val =~ s/\r/\\r/gs;
    $val = escapeHTML($val);
    dprint "After protecting: $val\n";
    return
"$Foswiki::cfg{Plugins}{DBIQueryPlugin}{protectStart}${val}$Foswiki::cfg{Plugins}{DBIQueryPlugin}{protectEnd}";
}

=begin TML

---++ unprotectValue($string) -> $string
   *=$string= - string processed by protectValue

Restores =protecValue()='d =$string= to it's original form. Note that
protectStart/protectEnd limiting braces must be trimmed off the string
before it's being passed to the function.

NB. Shall become obsoleted as soon as the plugin rewritted to be based
totally on =registerTagHandler()= interface.

=cut

sub unprotectValue {
    my $val = shift;
    dprint "Before unprotecting: $val\n";
    my $request = Foswiki::Func::getRequestObject();
    $val = $request->unescapeHTML($val);
    $val =~ s/(?<!\\)\\n/\n/gs;
    $val =~ s/(?<!\\)\\r/\r/gs;
    $val =~ s/\\\\(n|r)/\\$1/gs;
    $val =~ s/\.(.)/$1/gs;
    dprint "After unprotecting: $val\n";
    return $val;
}

sub query_params {
    my $param_str = shift;

    my %params    = Foswiki::Func::extractParameters($param_str);
    my @list2hash = qw(unquoted protected multivalued);

    foreach my $param (@list2hash) {
        if ( defined $params{$param} ) {
            $params{$param} = { map { $_ => 1 } split " ", $params{$param} };
        }
        else {
            $params{$param} = {};
        }
    }

    return %params;
}

sub newQID {
    state $query_id = 0;
    return "DBI_CONTENT" . $query_id++;
}

sub registerQuery {
    my ( $qid, $params ) = @_;
    if ( $params->{subquery} ) {
        $queries{$qid}{subquery} = $params->{subquery};
        $subquery_map{ $params->{subquery} } = $qid;
        return "";
    }
    return "\%$qid\%";
}

sub storeDoQuery {
    my ( $param_str, $content ) = @_;
    my %params;
    my ( $meta, $conname );

    %params  = query_params($param_str);
    $conname = $params{_DEFAULT};

    my $qid = newQID;

    unless ( defined $content ) {
        if ( defined $params{topic}
            && Foswiki::Func::topicExists( undef, $params{topic} ) )
        {
            ( $meta, $content ) =
              Foswiki::Func::readTopic( undef, $params{topic}, undef, 1 );
            if ( defined $params{script} ) {
                return wikiErrMsg(
                    "%<nop>DBI_DO% script name must be a valid identifier")
                  unless $params{script} =~ /^\w\w*$/;
                if ( $content =~
                    /%DBI_CODE{"$params{script}"}%(.*?)%DBI_CODE%/s )
                {
                    $content = $1;
                }
                else {
                    undef $content;
                }
                if ( defined $content ) {
                    $content =~ s/^\s*%CODE{.*?}%(.*)%ENDCODE%\s*$/$1/s;
                    $content =~ s/^\s*<pre>(.*)<\/pre>\s*$/$1/s;
                }
            }
        }
        return wikiErrMsg("No code defined for this %<nop>DBI_DO% variable")
          unless defined $content;
    }

    $queries{$qid}{params}     = \%params;
    $queries{$qid}{connection} = $conname;
    $queries{$qid}{type}       = "do";
    $queries{$qid}{code}       = $content;
    my $script_name =
      $params{script} ? $params{script}
      : (
        $params{name} ? $params{name}
        : (
            $params{subquery} ? $params{subquery}
            : "dbi_do_script"
        )
      );
    $queries{$qid}{script_name} =
      $params{topic} ? "$params{topic}\:\:$script_name" : $script_name;

    return registerQuery( $qid, \%params );
}

sub storeQuery {
    my ( $param_str, $content ) = @_;
    my %params;
    my $conname;

    $conname = $params{_DEFAULT};

    %params = query_params($param_str);

    #return wikiErrMsg("This DBI connection is not defined: $conname.")
    #  unless db_connected($conname);

    my $qid = newQID;

    $queries{$qid}{params}     = \%params;
    $queries{$qid}{connection} = $conname;
    $queries{$qid}{type}       = 'query';
    $queries{$qid}{_nesting}   = 0;

    my $content_kwd = qr/\n\.(head(?:er)?|body|footer)\s*/s;

    my %map_kwd = ( head => header => );

    my @content = split $content_kwd, $content;

    my $statement = shift @content;

    for ( my $i = 1 ; $i < @content ; $i += 2 ) {
        $content[$i] =~ s/\n*$//s;
        $content[$i] =~ s/\n/ /gs;
        $content[$i] =~ s/(?<!\\)\\n/\n/gs;
        $content[$i] =~ s/\\\\n/\\n/gs;
        my $kwd = $map_kwd{ $content[ $i - 1 ] } || $content[ $i - 1 ];
        $queries{$qid}{$kwd} = $content[$i];
    }

    $queries{$qid}{statement} = $statement;

    #    dprint "Query data:\n", Dumper($queries{$qid});

    return registerQuery( $qid, \%params );
}

sub storeCallQuery {
    my ($param_str) = @_;
    my %params;

    my $qid = newQID;

    %params                  = Foswiki::Func::extractParameters($param_str);
    $queries{$qid}{columns}  = \%params;
    $queries{$qid}{call}     = $params{_DEFAULT};
    $queries{$qid}{type}     = 'query';
    $queries{$qid}{_nesting} = 0;

    return "\%$qid\%";
}

sub dbiCode {
    my ( $param_str, $content ) = @_;
    my %params;

    %params = Foswiki::Func::extractParameters($param_str);

    unless ( $content =~ /^\s*%CODE{.*?}%(.*)%ENDCODE%\s*$/s ) {
        $content = "<pre>$content</pre>";
    }

    return <<EOT;
<table width=\"100\%\" border=\"0\" cellspacing="5px">
  <tr>
    <td nowrap> *Script name* </td>
    <td> =$params{_DEFAULT}= </td>
  </tr>
  <tr valign="top">
    <td nowrap> *Script code* </td>
    <td> $content </td>
  </tr>
</table>
EOT
}

sub expandColumns {
    my ( $text, $columns ) = @_;

    dprint
">>>>> EXPANDING:\n--------------------------------\n$text\n--------------------------------\n";
    if ( keys %$columns ) {
        my $regex = "\%(" . join( "|", keys %$columns ) . ")\%";
        $text =~ s/$regex/$columns->{$1}/ge;
    }
    $text =~ s/\%DBI_(?:SUBQUERY|EXEC){(.*?)}\%/&subQuery($1, $columns)/ge;
    dprint
"<<<<< EXPANDED:\n--------------------------------\n$text\n--------------------------------\n";

    return $text;
}

sub executeQueryByType {
    my ( $qid, $columns ) = @_;
    $columns ||= {};
    my $query = $queries{$qid};
    return (
        $query->{type} eq 'query' ? getQueryResult( $qid, $columns )
        : (
            $query->{type} eq 'do' ? doQuery( $qid, $columns )
            :

             #			wikiErrMsg("INTERNAL: Query type `$query->{type}' is unknown.")
              ''
        )
    );
}

sub subQuery {
    my %params  = query_params(shift);
    my $columns = shift;
    dprint
"Processing subquery $params{_DEFAULT} => $subquery_map{$params{_DEFAULT}}";
    return executeQueryByType( $subquery_map{ $params{_DEFAULT} }, $columns );
}

sub getQueryResult {
    my ( $qid, $columns ) = @_;

    my $query = $queries{$qid};
    return wikiErrMsg("Subquery $qid is not defined.") unless defined $query;

    my $params = $query->{params} || {};
    my $conname = $params->{_DEFAULT};
    $columns ||= {};

    return wikiErrMsg("No access to query $conname DB at $web.$topic.")
      unless defined( $query->{call} )
      || db_access_allowed( $conname, "$web.$topic", 'allow_query' );

    if ( $query->{_nesting} >
        $Foswiki::cfg{Plugins}{DBIQueryPlugin}{maxRecursionLevel} )
    {
        my $errmsg =
"Deep recursion (more then $Foswiki::cfg{Plugins}{DBIQueryPlugin}{maxRecursionLevel}) occured for subquery $params->{subquery}";
        warning $errmsg;
        throw Error::Simple($errmsg);
    }

    my $result = "";

    if ( defined $query->{call} ) {

        $result =
          getQueryResult( $subquery_map{ $query->{call} }, $query->{columns} );

    }
    else {
        $query->{_nesting}++;
        dprint "Nesting level $query->{_nesting} for subquery ",
          ( $query->{subquery} || "UNDEFINED" ), "....\n";
        $columns->{".nesting."} = $query->{_nesting};

        my $dbh = $query->{dbh} = db_connect( $params->{_DEFAULT} );
        throw Error::Simple(
            "DBI connect error for connection " . $params->{_DEFAULT} )
          unless $dbh;

        if ( defined $query->{header} ) {
            $result .= expandColumns( $query->{header}, $columns );
        }

        my $statement =
          Foswiki::Func::expandCommonVariables(
            expandColumns( $query->{statement}, $columns ),
            $topic, $web );
        $query->{expanded_statement} = $statement;
        dprint $statement;

        my $sth = $dbh->prepare($statement);
        $sth->execute;

        my $fetched = 0;
        while ( my $row = $sth->fetchrow_hashref ) {
            unless ($fetched) {
                dprint "Columns: ", join( ", ", keys %$row );
            }
            $fetched++;

            # Prepare row for output;
            foreach my $col ( keys %$row ) {
                if ( $col =~ /\s/ ) {
                    ( my $out_col = $col ) =~ s/\s/_/;
                    $row->{$out_col} = $row->{$col};
                    delete $row->{$col};
                    $col = $out_col;
                }
                $row->{$col} = '_NULL_' unless defined $row->{$col};
                $row->{$col} = nl2br( escapeHTML( $row->{$col} ) )
                  unless defined $params->{unquoted}{$col};
                $row->{$col} = protectValue( $row->{$col} )
                  if $params->{protected}{$col};
            }

            my $all_columns = { %$columns, %$row };
            my $out = expandColumns( $query->{body}, $all_columns );
            $result .= $out;
        }

        if ( $fetched > 0 || $query->{_nesting} < 2 ) {
            if ( defined $query->{footer} ) {
                $result .= expandColumns( $query->{footer}, $columns );
            }
        }
        else {
            # Avoid any output for empty recursively called subqueries.
            $result = "";
        }

        $query->{_nesting}--;
    }

    return $result;
}

sub doQuery {
    my ( $qid, $columns ) = @_;

    my $query   = $queries{$qid};
    my $params  = $query->{params} || {};
    my $rc      = "";
    my $conname = $params->{_DEFAULT};
    $columns ||= {};

    dprint "doQuery()\n";

    return wikiErrMsg("No access to modify $conname DB at $web.$topic.")
      unless db_access_allowed( $conname, "$web.$topic", 'allow_do' );

    my %multivalued;
    if ( defined $params->{multivalued} ) {
        %multivalued = %{ $params->{multivalued} };
    }

    # Preparing sub() code.
    my $dbh = $query->{dbh} = db_connect($conname);
    throw Error::Simple( "DBI connect error for connection " . $conname )
      unless $dbh;
    my $request = Foswiki::Func::getRequestObject();
    dprint( "REQUEST ACTIONS: ", $request->action, " thru ", $request->method );
    dprint( "REQUEST PARAMETERS: {", join( "}{", $request->param ), "}\n" );
    dprint("REQUEST TOPC: $web.$topic\n");
    my $sub_code = <<EOC;
sub {
        my (\$dbh, \$request, \$varParams, \$dbRecord) = \@_;
        my \@cgiParams = \$request->param;
        my \%httpParams;
        foreach my \$cgiParam (\@cgiParams) {
            dprint("QUERYING CGI parameter \$cgiParam");
            my \@val = \$request->param(\$cgiParam);
            \$httpParams{\$cgiParam} = (\$multivalued{\$cgiParam} || (\@val > 1)) ? \\\@val : \$val[0];
        }
        dprint( "doQuery code for $web.$topic\n" );
        my \$rc = "";

        try {
#line 1,"$query->{script_name}"
            $query->{code}
        } catch Error::Simple with {
            \$rc .= wikiErrMsg(shift->{-text});
        } otherwise {
            throw @_;
        };

        return \$rc;
}
EOC

    my $sub = eval $sub_code;
    return wikiErrMsg($@) if $@;
    $rc = $sub->( $dbh, $request, $params, $columns );

    return $rc;
}

sub handleQueries {
    foreach my $qid ( sort keys %queries ) {
        my $query = $queries{$qid};
        dprint "Processing query $qid\n";
        try {
            $query->{result} = executeQueryByType($qid)
              unless $query->{subquery};
        }
        catch Error::Simple with {
            my $err = shift;
            warning $err->{-text};
            my $query_text = "";
            if ( defined $query->{expanded_statement} ) {
                $query_text = "<br><pre>$query->{expanded_statement}</pre>";
            }
            if ( $Foswiki::cfg{Plugins}{DBIQueryPlugin}{Debug} ) {
                $query->{result} =
                  wikiErrMsg( "<pre>", $err->stacktrace, "</pre>",
                    $query_text );
            }
            else {
                $query->{result} = wikiErrMsg("$err->{-text}$query_text");
            }
        }
        otherwise {
            warning
"There is a problem with QID $qid on connection $queries{$qid}{connection}";
            my $errstr;
            if ( defined $queries{$qid}{dbh} ) {
                $errstr = $queries{$qid}{dbh}->errstr;
            }
            else {
                $errstr = $DBI::errstr;
            }
            warning "DBI Error for query $qid: $errstr";
            $query->{result} = wikiErrMsg("DBI Error: $errstr");
        };
        dprint "RESULT:\n",
          defined $query->{result} ? $query->{result} : "*UNDEFINED*";
    }
}

sub processPage {
    state $level = 0;

    $level++;
    dprint "### $level\n\n";

    my $doHandle = 0;
    $_[0] =~ s/%DBI_VERSION%/$VERSION/gs;
    if (
        $_[0] =~ s/%DBI_DO{(.*?)}%(?:(.*?)%DBI_DO%)?/&storeDoQuery($1, $2)/ges )
    {
        $doHandle = 1;
    }
    $_[0] =~ s/\%DBI_CODE{(.*?)}%(.*?)\%DBI_CODE%/&dbiCode($1, $2)/ges;
    if ( $_[0] =~ s/%DBI_QUERY{(.*?)}%(.*?)%DBI_QUERY%/&storeQuery($1, $2)/ges )
    {
        $doHandle = 1;
    }
    if ( $_[0] =~ s/%DBI_CALL{(.*?)}%/&storeCallQuery($1)/ges ) {
        $doHandle = 1;
    }
    if ($doHandle) {
        handleQueries;
        $_[0] =~ s/%(DBI_CONTENT\d+)%/$queries{$1}{result}/ges;
    }

    # Do not disconnect from databases if processing inclusions.

    $level--;

    db_disconnect if $level < 1;
}

=begin TML

---++ initPlugin($topic, $web, $user) -> $boolean
   * =$topic= - the name of the topic in the current CGI query
   * =$web= - the name of the web in the current CGI query
   * =$user= - the login name of the user
   * =$installWeb= - the name of the web the plugin topic is in
     (usually the same as =$Foswiki::cfg{SystemWebName}=)

*REQUIRED*

Called to initialise the plugin. If everything is OK, should return
a non-zero value. On non-fatal failure, should write a message
using =Foswiki::Func::writeWarning= and return 0. In this case
%<nop>FAILEDPLUGINS% will indicate which plugins failed.

In the case of a catastrophic failure that will prevent the whole
installation from working safely, this handler may use 'die', which
will be trapped and reported in the browser.

__Note:__ Please align macro names with the Plugin name, e.g. if
your Plugin is called !FooBarPlugin, name macros FOOBAR and/or
FOOBARSOMETHING. This avoids namespace issues.

=cut

sub initPlugin {
    ( $topic, $web, $user, $installWeb ) = @_;

    dprint "DBIQueryPlugin::initPlugin(", join( ",", @_ ), ")";

    # check for Plugins.pm versions
    if ( $Foswiki::Plugins::VERSION < 2.3 ) {
        Foswiki::Func::writeWarning( 'Version mismatch between ',
            __PACKAGE__, ' and Plugins.pm' );
        return 0;
    }

    db_init || return 0;

    # Example code of how to get a preference value, register a macro
    # handler and register a RESTHandler (remove code you do not need)

    # Set your per-installation plugin configuration in LocalSite.cfg,
    # like this:
    # $Foswiki::cfg{Plugins}{DBIQueryPlugin}{ExampleSetting} = 1;
    # See %SYSTEMWEB%.DevelopingPlugins#ConfigSpec for information
    # on integrating your plugin configuration with =configure=.

    # Always provide a default in case the setting is not defined in
    # LocalSite.cfg.
    # my $setting = $Foswiki::cfg{Plugins}{DBIQueryPlugin}{ExampleSetting} || 0;

    # Register the _EXAMPLETAG function to handle %EXAMPLETAG{...}%
    # This will be called whenever %EXAMPLETAG% or %EXAMPLETAG{...}% is
    # seen in the topic text.

    # TODO This is what DBIQueryPlugin shall be using instead of
    # pre/postprocessing parsing.
    # Foswiki::Func::registerTagHandler( 'EXAMPLETAG', \&_EXAMPLETAG );

    # Allow a sub to be called from the REST interface
    # using the provided alias.  This example enables strong
    # core enforced security for the handler, and is the default configuration
    # as of Foswiki 1.1.2

   #Foswiki::Func::registerRESTHandler(
   #    'example', \&restExample,
   #    authenticate => 1,  # Set to 0 if handler should be useable by WikiGuest
   #    validate     => 1,  # Set to 0 to disable StrikeOne CSRF protection
   #    http_allow => 'POST', # Set to 'GET,POST' to allow use HTTP GET and POST
   #    description => 'Example handler for Empty Plugin'
   #);

    # Plugin correctly initialized
    dprint "initPlugin for $web.$topic is OK";
    return 1;
}

# The function used to handle the %EXAMPLETAG{...}% macro
# You would have one of these for each macro you want to process.
#sub _EXAMPLETAG {
#    my($session, $params, $topic, $web, $topicObject) = @_;
#    # $session  - a reference to the Foswiki session object
#    #             (you probably won't need it, but documented in Foswiki.pm)
#    # $params=  - a reference to a Foswiki::Attrs object containing
#    #             parameters.
#    #             This can be used as a simple hash that maps parameter names
#    #             to values, with _DEFAULT being the name for the default
#    #             (unnamed) parameter.
#    # $topic    - name of the topic in the query
#    # $web      - name of the web in the query
#    # $topicObject - a reference to a Foswiki::Meta object containing the
#    #             topic the macro is being rendered in (new for foswiki 1.1.x)
#    # Return: the result of processing the macro. This will replace the
#    # macro call in the final text.
#
#    # For example, %EXAMPLETAG{'hamburger' sideorder="onions"}%
#    # $params->{_DEFAULT} will be 'hamburger'
#    # $params->{sideorder} will be 'onions'
#}

=begin TML

---+++ preload($class, $session)

This method is called as early as possible in the processing of a request;
before =initPlugin= is called, before any preferences are loaded, before
even the store is loaded, and before the user has been identified.

It is intended for use when there is sufficient information available
from the request object and the environment to make a decision
on something. For example, it could be used to check the source IP
address of a request, and decide whether to service it or not.

=preload= can use the methods of =Foswiki::Func= to access the request,
but must not access the store, or any user or preference information.
Caveat emptor! You have been warned!

The best way to terminate the request from =preload= is to throw an
exception. You can do this using a =die=, which will result in a
=text/plain= response being sent to the client. More sophisticated
implementations can use =Foswiki::OopsException= to craft a response.

*Since:* Foswiki 2.0

=cut

# sub preload {
#     die( "Terminate this session" );
# }

=begin TML

---++ earlyInitPlugin()

This method is called after =preload= but before =initPlugin=. It is
called after the Foswiki infrastructure has been set up. If it returns
a non-null error string, the plugin will be disabled. You can also
terminate the request from this method by throwing one of the
exceptions handled by =Foswiki::UI= (for example, =Foswiki::OopsException=).

=cut

#sub earlyInitPlugin {
#    return undef;
#}

=begin TML

---++ initializeUserHandler( $loginName, $url, $pathInfo )
   * =$loginName= - login name recovered from $ENV{REMOTE_USER}
   * =$url= - request url
   * =$path_info= - path_info from the Foswiki::Request
Allows a plugin to set the username. Normally Foswiki gets the username
from the login manager. This handler gives you a chance to override the
login manager.

Return the *login* name.

This handler is called very early, immediately after =earlyInitPlugin=.

*Since:* Foswiki::Plugins::VERSION = '2.0'

=cut

#sub initializeUserHandler {
#    my ( $loginName, $url, $path_info ) = @_;
#}

=begin TML

---++ finishPlugin()

Called when Foswiki is shutting down, this handler can be used by the plugin
to release resources - for example, shut down open database connections,
release allocated memory etc.

Note that it's important to break any cycles in memory allocated by plugins,
or that memory will be lost when Foswiki is run in a persistent context
e.g. mod_perl.

=cut

#sub finishPlugin {
#}

=begin TML

---++ validateRegistrationHandler($data)
   * =$data= - a hashref containing all the formfields POSTed to the registration script

Called when a new user registers with this Foswiki. The handler is called after the
user data has been validated by the core, but *before* the user is created and *before*
any validation mail is sent out. The handler will be called on all plugins that implement
it.

Note that the handler may modify fields in the $data record, but must be aware that
these fields have already been checked and validated before the handler is called,
so modifying them is dangerous, and strictly at the plugin author's own risk.

If the handler needs to abort the registration for any reason it can do so by raising
an exception ( e.g. using =die= )

*Since:* Foswiki::Plugins::VERSION = '2.0'

=cut

#sub validateRegistrationHandler {
#    my ( $data ) = @_;
#}

=begin TML

---++ commonTagsHandler($text, $topic, $web, $included, $meta )
   * =$text= - text to be processed
   * =$topic= - the name of the topic in the current CGI query
   * =$web= - the name of the web in the current CGI query
   * =$included= - Boolean flag indicating whether the handler is
     invoked on an included topic
   * =$meta= - meta-data object for the topic MAY BE =undef=
This handler is called by the code that expands %<nop>MACROS% syntax in
the topic body and in form fields. It may be called many times while
a topic is being rendered.

Only plugins that have to parse the entire topic content should implement
this function. For expanding macros with trivial syntax it is *far* more
efficient to use =Foswiki::Func::registerTagHandler= (see =initPlugin=).

Internal Foswiki macros, (and any macros declared using
=Foswiki::Func::registerTagHandler=) are expanded _before_, and then again
_after_, this function is called to ensure all %<nop>MACROS% are expanded.

*NOTE:* when this handler is called, &lt;verbatim> blocks have been
removed from the text (though all other blocks such as &lt;pre> and
&lt;noautolink> are still present).

*NOTE:* meta-data is _not_ embedded in the text passed to this
handler. Use the =$meta= object.

*NOTE:* Read the developer supplement at
Foswiki:Development.AddToZoneFromPluginHandlers if you are calling
=addToZone()= from this handler

*Since:* $Foswiki::Plugins::VERSION 2.0

=cut

sub commonTagsHandler {
    ( undef, $topic, $web ) = @_;

    dprint("CommonTagsHandler( $_[2].$_[1] )");
    if ( $_[3] ) {    # We're being included
        processPage(@_);
    }
}

=begin TML

---++ beforeCommonTagsHandler($text, $topic, $web, $meta )
   * =$text= - text to be processed
   * =$topic= - the name of the topic in the current CGI query
   * =$web= - the name of the web in the current CGI query
   * =$meta= - meta-data object for the topic MAY BE =undef=
This handler is called before Foswiki does any expansion of its own
internal variables. It is designed for use by cache plugins. Note that
when this handler is called, &lt;verbatim> blocks are still present
in the text.

*NOTE*: This handler is called once for each call to
=commonTagsHandler= i.e. it may be called many times during the
rendering of a topic.

*NOTE:* meta-data is _not_ embedded in the text passed to this
handler.

*NOTE:* This handler is not separately called on included topics.

*NOTE:* Read the developer supplement at
Foswiki:Development.AddToZoneFromPluginHandlers if you are calling
=addToZone()= from this handler

=cut

sub beforeCommonTagsHandler {
    ( undef, $topic, $web ) = @_;

    dprint "Starting processing.";

    #    my ( $text, $topic, $web, $meta ) = @_;
    #
    #    # You can work on $text in place by using the special perl
    #    # variable $_[0]. These allow you to operate on $text
    #    # as if it was passed by reference; for example:
    #    # $_[0] =~ s/SpecialString/my alternative/ge;
    processPage(@_);
}

=begin TML

---++ afterCommonTagsHandler($text, $topic, $web, $meta )
   * =$text= - text to be processed
   * =$topic= - the name of the topic in the current CGI query
   * =$web= - the name of the web in the current CGI query
   * =$meta= - meta-data object for the topic MAY BE =undef=
This handler is called after Foswiki has completed expansion of %MACROS%.
It is designed for use by cache plugins. Note that when this handler
is called, &lt;verbatim> blocks are present in the text.

*NOTE*: This handler is called once for each call to
=commonTagsHandler= i.e. it may be called many times during the
rendering of a topic.

*NOTE:* meta-data is _not_ embedded in the text passed to this
handler.

*NOTE:* Read the developer supplement at
Foswiki:Development.AddToZoneFromPluginHandlers if you are calling
=addToZone()= from this handler

=cut

#sub afterCommonTagsHandler {
#    my ( $text, $topic, $web, $meta ) = @_;
#
#    # You can work on $text in place by using the special perl
#    # variable $_[0]. These allow you to operate on $text
#    # as if it was passed by reference; for example:
#    # $_[0] =~ s/SpecialString/my alternative/ge;
#}

=begin TML

---++ preRenderingHandler( $text, \%map )
   * =$text= - text, with the head, verbatim and pre blocks replaced
     with placeholders
   * =\%removed= - reference to a hash that maps the placeholders to
     the removed blocks.

Handler called immediately before Foswiki syntax structures (such as lists) are
processed, but after all variables have been expanded. Use this handler to
process special syntax only recognised by your plugin.

Placeholders are text strings constructed using the tag name and a
sequence number e.g. 'pre1', "verbatim6", "head1" etc. Placeholders are
inserted into the text inside &lt;!--!marker!--&gt; characters so the
text will contain &lt;!--!pre1!--&gt; for placeholder pre1.

Each removed block is represented by the block text and the parameters
passed to the tag (usually empty) e.g. for
<verbatim>
<pre class='slobadob'>
XYZ
</pre>
</verbatim>
the map will contain:
<pre>
$removed->{'pre1'}{text}:   XYZ
$removed->{'pre1'}{params}: class="slobadob"
</pre>
Iterating over blocks for a single tag is easy. For example, to prepend a
line number to every line of every pre block you might use this code:
<verbatim>
foreach my $placeholder ( keys %$map ) {
    if( $placeholder =~ m/^pre/i ) {
        my $n = 1;
        $map->{$placeholder}{text} =~ s/^/$n++/gem;
    }
}
</verbatim>

__NOTE__: This handler is called once for each rendered block of text i.e.
it may be called several times during the rendering of a topic.

*NOTE:* meta-data is _not_ embedded in the text passed to this
handler.

*NOTE:* Read the developer supplement at
Foswiki:Development.AddToZoneFromPluginHandlers if you are calling
=addToZone()= from this handler

Since Foswiki::Plugins::VERSION = '2.0'

=cut

#sub preRenderingHandler {
#    my( $text, $pMap ) = @_;
#
#    # You can work on $text in place by using the special perl
#    # variable $_[0]. These allow you to operate on $text
#    # as if it was passed by reference; for example:
#    # $_[0] =~ s/SpecialString/my alternative/ge;
#}

=begin TML

---++ postRenderingHandler( $text )
   * =$text= - the text that has just been rendered. May be modified in place.

*NOTE*: This handler is called once for each rendered block of text i.e. 
it may be called several times during the rendering of a topic.

*NOTE:* meta-data is _not_ embedded in the text passed to this
handler.

*NOTE:* Read the developer supplement at
Foswiki:Development.AddToZoneFromPluginHandlers if you are calling
=addToZone()= from this handler

Since Foswiki::Plugins::VERSION = '2.0'

=cut

sub postRenderingHandler {

    #    my $text = shift;
    #    # You can work on $text in place by using the special perl
    #    # variable $_[0]. These allow you to operate on $text
    #    # as if it was passed by reference; for example:
    #    # $_[0] =~ s/SpecialString/my alternative/ge;

    dprint "endRenderingHandler( $web.$topic )";

    $_[0] =~
s/$Foswiki::cfg{Plugins}{DBIQueryPlugin}{protectStart}(.*?)$Foswiki::cfg{Plugins}{DBIQueryPlugin}{protectEnd}/&unprotectValue($1)/ges;
}

=begin TML

---++ beforeEditHandler($text, $topic, $web )
   * =$text= - text that will be edited
   * =$topic= - the name of the topic in the current CGI query
   * =$web= - the name of the web in the current CGI query
This handler is called by the edit script just before presenting the edit text
in the edit box. It is called once when the =edit= script is run.

*NOTE*: meta-data may be embedded in the text passed to this handler 
(using %META: tags)

*Since:* Foswiki::Plugins::VERSION = '2.0'

=cut

#sub beforeEditHandler {
#    my ( $text, $topic, $web ) = @_;
#
#    # You can work on $text in place by using the special perl
#    # variable $_[0]. These allow you to operate on $text
#    # as if it was passed by reference; for example:
#    # $_[0] =~ s/SpecialString/my alternative/ge;
#}

=begin TML

---++ afterEditHandler($text, $topic, $web, $meta )
   * =$text= - text that is being previewed
   * =$topic= - the name of the topic in the current CGI query
   * =$web= - the name of the web in the current CGI query
   * =$meta= - meta-data for the topic.
This handler is called by the preview script just before presenting the text.
It is called once when the =preview= script is run.

*NOTE:* this handler is _not_ called unless the text is previewed.

*NOTE:* meta-data is _not_ embedded in the text passed to this
handler. Use the =$meta= object.

*Since:* $Foswiki::Plugins::VERSION 2.0

=cut

#sub afterEditHandler {
#    my ( $text, $topic, $web ) = @_;
#
#    # You can work on $text in place by using the special perl
#    # variable $_[0]. These allow you to operate on $text
#    # as if it was passed by reference; for example:
#    # $_[0] =~ s/SpecialString/my alternative/ge;
#}

=begin TML

---++ beforeSaveHandler($text, $topic, $web, $meta )
   * =$text= - text _with embedded meta-data tags_
   * =$topic= - the name of the topic in the current CGI query
   * =$web= - the name of the web in the current CGI query
   * =$meta= - the metadata of the topic being saved, represented by a Foswiki::Meta object.

This handler is called each time a topic is saved.

*NOTE:* meta-data is embedded in =$text= (using %META: tags). If you modify
the =$meta= object, then it will override any changes to the meta-data
embedded in the text. Modify *either* the META in the text *or* the =$meta=
object, never both. You are recommended to modify the =$meta= object rather
than the text, as this approach is proof against changes in the embedded
text format.

*Since:* Foswiki::Plugins::VERSION = 2.0

=cut

#sub beforeSaveHandler {
#    my ( $text, $topic, $web ) = @_;
#
#    # You can work on $text in place by using the special perl
#    # variable $_[0]. These allow you to operate on $text
#    # as if it was passed by reference; for example:
#    # $_[0] =~ s/SpecialString/my alternative/ge;
#}

=begin TML

---++ afterSaveHandler($text, $topic, $web, $error, $meta )
   * =$text= - the text of the topic _excluding meta-data tags_
     (see beforeSaveHandler)
   * =$topic= - the name of the topic in the current CGI query
   * =$web= - the name of the web in the current CGI query
   * =$error= - any error string returned by the save.
   * =$meta= - the metadata of the saved topic, represented by a Foswiki::Meta object 

This handler is called each time a topic is saved.

*NOTE:* meta-data is embedded in $text (using %META: tags)

*Since:* Foswiki::Plugins::VERSION 2.0

=cut

#sub afterSaveHandler {
#    my ( $text, $topic, $web, $error, $meta ) = @_;
#
#    # You can work on $text in place by using the special perl
#    # variable $_[0]. These allow you to operate on $text
#    # as if it was passed by reference; for example:
#    # $_[0] =~ s/SpecialString/my alternative/ge;
#}

=begin TML

---++ afterRenameHandler( $oldWeb, $oldTopic, $oldAttachment, $newWeb, $newTopic, $newAttachment )

   * =$oldWeb= - name of old web
   * =$oldTopic= - name of old topic (empty string if web rename)
   * =$oldAttachment= - name of old attachment (empty string if web or topic rename)
   * =$newWeb= - name of new web
   * =$newTopic= - name of new topic (empty string if web rename)
   * =$newAttachment= - name of new attachment (empty string if web or topic rename)

This handler is called just after the rename/move/delete action of a web, topic or attachment.

*Since:* Foswiki::Plugins::VERSION = '2.0'

=cut

#sub afterRenameHandler {
#    my ( $oldWeb, $oldTopic, $oldAttachment,
#         $newWeb, $newTopic, $newAttachment ) = @_;
#}

=begin TML

---++ beforeUploadHandler(\%attrHash, $meta )
   * =\%attrHash= - reference to hash of attachment attribute values
   * =$meta= - the Foswiki::Meta object where the upload will happen

This handler is called once when an attachment is uploaded. When this
handler is called, the attachment has *not* been recorded in the database.

The attributes hash will include at least the following attributes:
   * =attachment= => the attachment name - must not be modified
   * =user= - the user id - must not be modified
   * =comment= - the comment - may be modified
   * =stream= - an input stream that will deliver the data for the
     attachment. The stream can be assumed to be seekable, and the file
     pointer will be positioned at the start. It is *not* necessary to
     reset the file pointer to the start of the stream after you are
     done, nor is it necessary to close the stream.

The handler may wish to replace the original data served by the stream
with new data. In this case, the handler can set the ={stream}= to a
new stream.

For example:
<verbatim>
sub beforeUploadHandler {
    my ( $attrs, $meta ) = @_;
    my $fh = $attrs->{stream};
    local $/;
    # read the whole stream
    my $text = <$fh>;
    # Modify the content
    $text =~ s/investment bank/den of thieves/gi;
    $fh = new File::Temp();
    print $fh $text;
    $attrs->{stream} = $fh;

}
</verbatim>

*Since:* Foswiki::Plugins::VERSION = 2.1

=cut

#sub beforeUploadHandler {
#    my( $attrHashRef, $topic, $web ) = @_;
#}

=begin TML

---++ afterUploadHandler(\%attrHash, $meta )
   * =\%attrHash= - reference to hash of attachment attribute values
   * =$meta= - a Foswiki::Meta  object where the upload has happened

This handler is called just after the after the attachment
meta-data in the topic has been saved. The attributes hash
will include at least the following attributes, all of which are read-only:
   * =attachment= => the attachment name
   * =comment= - the comment
   * =user= - the user id

*Since:* Foswiki::Plugins::VERSION = 2.1

=cut

#sub afterUploadHandler {
#    my( $attrHashRef, $meta ) = @_;
#}

=begin TML

---++ mergeHandler( $diff, $old, $new, \%info ) -> $text
Try to resolve a difference encountered during merge. The =differences= 
array is an array of hash references, where each hash contains the 
following fields:
   * =$diff= => one of the characters '+', '-', 'c' or ' '.
      * '+' - =new= contains text inserted in the new version
      * '-' - =old= contains text deleted from the old version
      * 'c' - =old= contains text from the old version, and =new= text
        from the version being saved
      * ' ' - =new= contains text common to both versions, or the change
        only involved whitespace
   * =$old= => text from version currently saved
   * =$new= => text from version being saved
   * =\%info= is a reference to the form field description { name, title,
     type, size, value, tooltip, attributes, referenced }. It must _not_
     be wrtten to. This parameter will be undef when merging the body
     text of the topic.

Plugins should try to resolve differences and return the merged text. 
For example, a radio button field where we have 
={ diff=>'c', old=>'Leafy', new=>'Barky' }= might be resolved as 
='Treelike'=. If the plugin cannot resolve a difference it should return 
undef.

The merge handler will be called several times during a save; once for 
each difference that needs resolution.

If any merges are left unresolved after all plugins have been given a 
chance to intercede, the following algorithm is used to decide how to 
merge the data:
   1 =new= is taken for all =radio=, =checkbox= and =select= fields to 
     resolve 'c' conflicts
   1 '+' and '-' text is always included in the the body text and text
     fields
   1 =&lt;del>conflict&lt;/del> &lt;ins>markers&lt;/ins>= are used to 
     mark 'c' merges in text fields

The merge handler is called whenever a topic is saved, and a merge is 
required to resolve concurrent edits on a topic.

*Since:* Foswiki::Plugins::VERSION = 2.0

=cut

#sub mergeHandler {
#    my ( $diff, $old, $new, $info ) = @_;
#}

=begin TML

---++ modifyHeaderHandler( \%headers, $query )
   * =\%headers= - reference to a hash of existing header values
   * =$query= - reference to CGI query object
Lets the plugin modify the HTTP headers that will be emitted when a
page is written to the browser. \%headers= will contain the headers
proposed by the core, plus any modifications made by other plugins that also
implement this method that come earlier in the plugins list.
<verbatim>
$headers->{expires} = '+1h';
</verbatim>

Note that this is the HTTP header which is _not_ the same as the HTML
&lt;HEAD&gt; tag. The contents of the &lt;HEAD&gt; tag may be manipulated
using the =Foswiki::Func::addToHEAD= method.

*Since:* Foswiki::Plugins::VERSION 2.0

=cut

#sub modifyHeaderHandler {
#    my ( $headers, $query ) = @_;
#}

=begin TML

---++ renderFormFieldForEditHandler($name, $type, $size, $value, $attributes, $possibleValues) -> $html

This handler is called before built-in types are considered. It generates 
the HTML text rendering this form field, or false, if the rendering 
should be done by the built-in type handlers.
   * =$name= - name of form field
   * =$type= - type of form field (checkbox, radio etc)
   * =$size= - size of form field
   * =$value= - value held in the form field
   * =$attributes= - attributes of form field 
   * =$possibleValues= - the values defined as options for form field, if
     any. May be a scalar (one legal value) or a ref to an array
     (several legal values)

Return HTML text that renders this field. If false, form rendering
continues by considering the built-in types.

*Since:* Foswiki::Plugins::VERSION 2.0

Note that you can also extend the range of available
types by providing a subclass of =Foswiki::Form::FieldDefinition= to implement
the new type (see =Foswiki::Extensions.JSCalendarContrib= and
=Foswiki::Extensions.RatingContrib= for examples). This is the preferred way to
extend the form field types.

=cut

#sub renderFormFieldForEditHandler {
#    my ( $name, $type, $size, $value, $attributes, $possibleValues) = @_;
#}

=begin TML

---++ renderWikiWordHandler($linkText, $hasExplicitLinkLabel, $web, $topic) -> $linkText
   * =$linkText= - the text for the link i.e. for =[<nop>[Link][blah blah]]=
     it's =blah blah=, for =BlahBlah= it's =BlahBlah=, and for [[Blah Blah]] it's =Blah Blah=.
   * =$hasExplicitLinkLabel= - true if the link is of the form =[<nop>[Link][blah blah]]= (false if it's ==<nop>[Blah]] or =BlahBlah=)
   * =$web=, =$topic= - specify the link being rendered

Called during rendering, this handler allows the plugin a chance to change
the rendering of labels used for links.

Return the new link text.

NOTE: this handler is to allow a plugin to change the link text for a possible link - it may never be used.
for example, Set ALLOWTOPICVIEW = is a possible ACRONYM link that will not be displayed unless the topic exists
similarly, this handler is called before the Plurals code has a chance to remove the 's' from WikiWords

*Since:* Foswiki::Plugins::VERSION 2.0

=cut

#sub renderWikiWordHandler {
#    my( $linkText, $hasExplicitLinkLabel, $web, $topic ) = @_;
#    return $linkText;
#}

=begin TML

---++ completePageHandler($html, $httpHeaders)

This handler is called on the ingredients of every page that is
output by the standard CGI scripts. It is designed primarily for use by
cache and security plugins.
   * =$html= - the body of the page (normally &lt;html>..$lt;/html>)
   * =$httpHeaders= - the HTTP headers. Note that the headers do not contain
     a =Content-length=. That will be computed and added immediately before
     the page is actually written. This is a string, which must end in \n\n.

*Since:* Foswiki::Plugins::VERSION 2.0

=cut

#sub completePageHandler {
#    my( $html, $httpHeaders ) = @_;
#    # modify $_[0] or $_[1] if you must change the HTML or headers
#    # You can work on $html and $httpHeaders in place by using the
#    # special perl variables $_[0] and $_[1]. These allow you to operate
#    # on parameters as if they were passed by reference; for example:
#    # $_[0] =~ s/SpecialString/my alternative/ge;
#}

=begin TML

---++ restExample($session, $subject, $verb, $response) -> $text
   * =$session= - The Foswiki object associated with this request.
   * =$subject= - The invoked subject (may be ignored)
   * =$verb= - The invoked verb (may be ignored)
   * =$response= reference to the Foswiki::Response object that is used to compose a reply to the request

If the =redirectto= parameter is not present on the request, then the return
value from the handler is used to determine the endpoint for the
request. It can be:
   * =undef= - causes the core to assume the handler handled the complete
     request i.e. the core will not generate any response to the request.
   * =text= - any other non-undef value will be written out as the content
     of an HTTP 200 response. Only the standard headers in the response are
     written.

Additional parameters can be recovered via the query object in the $session, for example:

my $query = $session->{request};
my $web = $query->{param}->{web}[0];

If your rest handler adds or replaces equivalent functionality to a standard script
provided with Foswiki, it should set the appropriate context in its switchboard entry.
In addition to the obvous contexts:  =view=, =diff=,  etc. the =static= context is used
to indicate that the resulting output will be read offline, such as in a PDF,  and 
dynamic links (edit, sorting, etc) should not be rendered.

A comprehensive list of core context identifiers used by Foswiki is found in
%SYSTEMWEB%.IfStatements#Context_identifiers. Please be careful not to
overwrite any of these identifiers!

For more information, check %SYSTEMWEB%.CommandAndCGIScripts#rest

For information about handling error returns from REST handlers, see
Foswiki:Support.Faq1

*Since:* Foswiki::Plugins::VERSION 2.0

=cut

#sub restExample {
#   my ( $session, $subject, $verb, $response ) = @_;
#   return "This is an example of a REST invocation\n\n";
#}

=begin TML

---++ Deprecated handlers

---+++ redirectCgiQueryHandler($query, $url )
   * =$query= - the CGI query
   * =$url= - the URL to redirect to

This handler can be used to replace Foswiki's internal redirect function.

If this handler is defined in more than one plugin, only the handler
in the earliest plugin in the INSTALLEDPLUGINS list will be called. All
the others will be ignored.

*Deprecated in:* Foswiki::Plugins::VERSION 2.1

This handler was deprecated because it cannot be guaranteed to work, and
caused a significant impediment to code improvements in the core.

---+++ beforeAttachmentSaveHandler(\%attrHash, $topic, $web )

   * =\%attrHash= - reference to hash of attachment attribute values
   * =$topic= - the name of the topic in the current CGI query
   * =$web= - the name of the web in the current CGI query
This handler is called once when an attachment is uploaded. When this
handler is called, the attachment has *not* been recorded in the database.

The attributes hash will include at least the following attributes:
   * =attachment= => the attachment name
   * =comment= - the comment
   * =user= - the user id
   * =tmpFilename= - name of a temporary file containing the attachment data

*Deprecated in:* Foswiki::Plugins::VERSION 2.1

The efficiency of this handler (and therefore it's impact on performance)
is very bad. Please use =beforeUploadHandler()= instead.

=begin TML

---+++ afterAttachmentSaveHandler(\%attrHash, $topic, $web )

   * =\%attrHash= - reference to hash of attachment attribute values
   * =$topic= - the name of the topic in the current CGI query
   * =$web= - the name of the web in the current CGI query
   * =$error= - any error string generated during the save process (always
     undef in 2.1)

This handler is called just after the save action. The attributes hash
will include at least the following attributes:
   * =attachment= => the attachment name
   * =comment= - the comment
   * =user= - the user id

*Deprecated in:* Foswiki::Plugins::VERSION 2.1

This handler has a number of problems including security and performance
issues. Please use =afterUploadHandler()= instead.

=cut

1;

__END__
Foswiki - The Free and Open Source Wiki, http://foswiki.org/

# Copyright (C) 2005-2015 Vadim Belman, vrurg@lflat.org
# Copyright (C) 2009 Foswiki:Main.ThomasWeigert
# Copyright (C) 2008-2011 Foswiki Contributors. All Rights Reserved.

Copyright (C) 2008-2013 Foswiki Contributors. Foswiki Contributors
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

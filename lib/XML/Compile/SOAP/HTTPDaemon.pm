use warnings;
use strict;

package XML::Compile::SOAP::HTTPDaemon;
use base 'XML::Compile::SOAP::Daemon';

use Log::Report 'xml-compile-soap-daemon', syntax => 'SHORT';

use XML::LibXML    ();
use List::Util     qw/first/;
use HTTP::Response ();
use HTTP::Status   qw/RC_BAD_REQUEST RC_OK RC_METHOD_NOT_ALLOWED
  RC_EXPECTATION_FAILED RC_NOT_ACCEPTABLE/;

use HTTP::Daemon   ();
use XML::Compile::SOAP::Util  qw/:daemon/;
use Time::HiRes    qw/time alarm/;

=chapter NAME
XML::Compile::SOAP::HTTPDaemon - create SOAP over HTTP daemon

=chapter SYNOPSIS
 # See XML::Compile::SOAP::Daemon for an example, but even better:
 # have a look at the example enclosed in the distribution package.
 
=chapter DESCRIPTION
This module handles the exchange of (XML) messages over HTTP,
according to the rules of SOAP (any version).

This abstraction level of the object (code in this pm file) is not
concerned with parsing or composing XML, but only worries about the
HTTP transport specifics of SOAP messages.  The creation and decoding
of the messages is handled by various M<XML::Compile::SOAP> components,
based on M<XML::Compile::Cache> and M<XML::Compile>.  The processing of
the message is handled by the M<XML::Compile::SOAP::Daemon> base-class.

The server is as flexible as possible: accept M-POST (HTTP Extension
Framework) and POST (standard HTTP) for any message.  It can be used
for any SOAP1.1 and SOAP1.2 mixture.  Although SOAP1.2 itself is
not implemented yet.

=chapter METHODS

=cut

my @default_headers;
sub make_default_headers
{   foreach my $pkg (qw/XML::Compile XML::Compile::SOAP
        XML::Compile::SOAP::Daemon XML::LibXML LWP/)
    {   no strict 'refs';
        my $version = ${"${pkg}::VERSION"} || 'undef';
        (my $field = "X-$pkg-Version") =~ s/\:\:/-/g;
        push @default_headers, $field => $version;
    }
    @default_headers;
}

sub options()
{   my ($self, $ref) = @_;
    my $prop = $self->{server};
    $self->SUPER::options($ref);
    foreach ( qw/client_timeout client_maxreq client_reqbonus name/ )
    {   $prop->{$_} = undef unless exists $prop->{$_};
        $ref->{$_} = \$prop->{$_};
    }
}

sub default_values()
{   my $self  = shift;
    my $def   = $self->SUPER::default_values;
    my %mydef = ( client_timeout => 30, client_maxreq => 100
     , client_reqbonus => 0, name => 'soap daemon');
    @$def{keys %mydef} = values %mydef;
    $def;
}

=section Handlers
=cut

sub process_request()
{   my $self = shift;
    my $prop = $self->{server};

    # Merge Net::Server behavior with HTTP::Daemon
    # Now, our connection will become a HTTP::Daemon connection
    my $old_class  = ref $prop->{client};
    my $connection = bless $prop->{client}, 'HTTP::Daemon::ClientConn';
    ${*$connection}{httpd_daemon} = $self;

    local $SIG{ALRM} = sub { die "timeout\n" };
    my $expires = time() + $prop->{client_timeout};
    my $maxmsgs = $prop->{client_maxreq};

    eval {
        my $timeleft;
        while(($timeleft = $expires - time) > 0.01)
        {   alarm $timeleft;
            my $request  = $connection->get_request;
            alarm 0;
            $request or last;

            my $response = $self->runRequest($request, $connection);
            $connection->force_last_request if $maxmsgs==1;
            $connection->send_response($response);

            --$maxmsgs or last;
            $expires += $prop->{client_reqbonus};
        }
    };

    info __x"connection ended with force; {error}", error => $@
        if $@;

    # Our connection becomes as Net::Server::Proto::TCP again
    bless $prop->{client}, $old_class;
    1;
}

sub url() { "url replacement not yet implemented" }
sub product_tokens() { shift->{prop}{name} }

=method runRequest REQUEST, [CONNECTION]
Handle one REQUEST (M<HTTP::Request> object), which was received from
the CLIENT (string).
=cut

sub runRequest($;$)
{   my ($self, $request, $connection) = @_;

#   my $client   = $connection->peerhost;
    if($request->method !~ m/^(?:M-)?POST/)
    {   return $self->makeResponse($request, RC_METHOD_NOT_ALLOWED
          , "only POST or M-POST"
          , "attempt to connect via ".$request->method);
    }

    my $media    = $request->content_type || 'text/plain';
    $media =~ m{[/+]xml$}i
        or return $self->makeResponse($request, RC_NOT_ACCEPTABLE
          , 'required is XML'
          , "content-type seems to be $media, must be some XML");

    my $action   = $self->actionFromHeader($request);
    my $ct       = $request->header('Content-Type');
    my $charset  = $ct =~ m/\;\s*type\=(["']?)([\w-]*)\1/ ? $2: 'utf-8';
    my $xmlin    = $request->decoded_content(charset => $charset, ref => 1);

    my ($status, $msg, $out) = $self->process($xmlin, $request, $action);
    $self->makeResponse($request, $status, $msg, $out);
}

=method makeResponse REQUEST, RC, MSG, BODY
=cut

sub makeResponse($$$$)
{   my ($self, $request, $status, $msg, $body) = @_;

    my $response = HTTP::Response->new($status, $msg);
    @default_headers or make_default_headers;
    $response->header(Server => $self->{prop}{name}, @default_headers);
    $response->protocol($request->protocol);  # match request's

    my $s;
    if(UNIVERSAL::isa($body, 'XML::LibXML::Document'))
    {   $s = $body->toString($status == RC_OK ? 0 : 1);
        $response->header('Content-Type' => 'text/xml; charset="utf-8"');
    }
    else
    {   $s = "[$status] $body";
        $response->header(Content_Type => 'text/plain');
    }

    $response->content_ref(\$s);
    { use bytes; $response->header('Content-Length' => length $s); }

    if(substr($request->method, 0, 2) eq 'M-')
    {   # HTTP extension framework.  More needed?
        $response->header(Ext => '');
    }

    $response;
}

#-----------------------------

=section Helpers

=method actionFromHeader REQUEST
Collect the soap action URI from the request, with C<undef> on failure.
Officially, the "SOAPAction" has no other purpose than the ability to
route messages over HTTP: it should not be linked to the portname of
the message (although it often can).
=cut

sub actionFromHeader($)
{   my ($self, $request) = @_;

    my $action;
    if($request->method eq 'POST')
    {   $action = $request->header('SOAPAction');
    }
    elsif($request->method eq 'M-POST')
    {   # Microsofts HTTP Extension Framework
        my $http_ext_id = '"' . MSEXT . '"';
        my $man = first { m/\Q$http_ext_id\E/ } $request->header('Man');
        defined $man or return undef;

        $man =~ m/\;\s*ns\=(\d+)/ or return undef;
        $action = $request->header("$1-SOAPAction");
    }
    else
    {   return undef;
    }

      !defined $action            ? undef
    : $action =~ m/^\s*\"(.*?)\"/ ? $1
    :                               '';
}

=chapter DETAILS

=section Configuration options

It depends on the type of M<Net::Server> which you extend,
which options are available to you on the command-line
or in a configuration file.  M<XML::Compile::SOAP::Daemon> adds and
changes some parameters as well.

Any C<XML::Compile::SOAP::HTTPDaemon> object will have the following
additional configuration options:

  Key             Value                            Default
  client_timeout  integer seconds                  30
  client_maxreq   integer                          100
  client_reqbonus integer seconds                  0
  name            string                           "soap daemon"

For each client, we like to have a reset of the connection after some
time, for two reasons: perl processes are usually leaking memory a bit
so should not live for ever, and you can experience denial of service
attacks.  The C<client_timeout> value details the number of seconds
a connection may live, but that will be increase by C<client_reqbonus>
for every received message.  In any case, after C<client_maxreq> messages
were handled, the connection will be terminated.

The C<name> is included in the reply messages.
=cut

1;

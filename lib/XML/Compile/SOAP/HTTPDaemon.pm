use warnings;
use strict;

package XML::Compile::SOAP::HTTPDaemon;
use base 'XML::Compile::SOAP::Daemon';

use Log::Report 'xml-compile-soap-daemon', syntax => 'SHORT';

use XML::LibXML    ();
use List::Util     qw/first/;
use HTTP::Response ();
use HTTP::Status   qw/RC_BAD_REQUEST RC_NOT_ACCEPTABLE
                      RC_OK RC_UNPROCESSABLE_ENTITY/;

use HTTP::Daemon   ();
use XML::Compile::SOAP::Util  qw/:daemon/;
use Time::HiRes    qw/time alarm/;

=chapter NAME
XML::Compile::SOAP::HTTPDaemon - create SOAP over HTTP daemon

=chapter SYNOPSIS
 # See XML::Compile::SOAP::Daemon for an example, but even better:
 # have a look at the example enclosed in the distribution package.
 
=chapter DESCRIPTION
This module handles the exchange of (XML) messages, according to the
rules of SOAP (any version).

This inheritance level of the object (code in this pm file) is not
concerned with parsing or composing XML, but only worries about the
HTTP transport specifics of SOAP messages.  The creation and decoding
of the messages is handled by various M<XML::Compile::SOAP> packages,
based on M<XML::Compile>.  The processing of the message is handled by
M<XML::Compile::SOAP::Daemon>.

The server is as flexible as possible: accept M-POST (HTTP Extension
Framework) and POST (standard HTTP) for any message.  It can be used
for any SOAP1.1 and SOAP1.2 mixture.  Although M<XML::Compile::SOAP>
does not implement SOAP1.2 yet.

=cut

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

sub headers($)
{   my ($self, $response) = @_;
    $response->header(Server => $self->{prop}{name});
    $self;
}

sub headersForXML($)
{  my ($self, $response) = @_;
   $self->headers($response);
   $response->header('Content-Type' => 'text/xml; charset="utf-8"');
   $self;
}

=chapter METHODS

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

    local $SIG{ALRM} = sub { die "timeout" };
    my $expires = time() + $prop->{client_timeout};
    my $maxmsgs = $prop->{client_maxreq};

    eval {
        my $timeleft;
        while(($timeleft = $expires - time) > 0.01)
        {   alarm $timeleft;
            my $request  = $connection->get_request or last;
            alarm 0;

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

=method runRequest REQUEST, CONNECTION
Handle one REQUEST (M<HTTP::Request> object), which was received from
the CLIENT (string).
=cut

sub runRequest($$)
{   my ($self, $request, $connection) = @_;

    my $client   = $connection->peerhost;
    my $media    = $request->content_type || 'text/plain';
    unless($media =~ m{[/+]xml$}i)
    {   info __x"request from {client} request not xml but {media}"
           , client => $client, media => $media;
        return HTTP::Response->new(RC_BAD_REQUEST);
    }

    my $action   = $self->actionFromHeader($request);
    unless(defined $action)
    {   info __x"request from {client} request not soap", client => $client;
        return HTTP::Response->new(RC_BAD_REQUEST);;
    }

    my $ct       = $request->header('Content-Type');
    my $charset  = $ct =~ m/\;\s*type\=(["']?)([\w-]*)\1/ ? $2: 'utf-8';

    my $text     = $request->decoded_content(charset => $charset, ref => 1);

    my $input    = $self->inputToXML($client, $action, $text)
        or return HTTP::Response->new(RC_NOT_ACCEPTABLE);

    my $response  = $self->process($request, $input);

    $response;
}

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

sub acceptResponse($$)
{   my ($self, $request, $output) = @_;
    my $xml    = $self->SUPER::acceptResponse($request, $output)
        or return;

    my $status = $xml->find('/Envelope/Body/Fault')
               ? RC_UNPROCESSABLE_ENTITY : RC_OK;

    my $resp   = HTTP::Response->new($status);
    $resp->protocol($request->protocol);  # match request
    my $s = $resp->content($xml->toString);
    { use bytes; $self->header('Content-Length' => length $s); }
    $self->headersForXML($resp);

    if(substr($request->method, 0, 2) eq 'M-')
    {   # HTTP extension framework.  More needed?
        $resp->header(Ext => '');
    }
    $resp;
}

sub soapFault($$$$)
{   my ($self, $version, $data, $rc, $abstract) = @_;
    my $doc  = $self->SUPER::soapFault($version, $data);
    my $resp = HTTP::Response->new($rc, $abstract);
    my $s = $resp->content($doc->toString);
    { use bytes; $self->header('Content-Length' => length $s); }
    $self->headersForXML($resp);
    $resp;
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

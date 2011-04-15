use warnings;
use strict;

package XML::Compile::SOAP::Daemon::LWPutil;
use base 'Exporter';

=chapter NAME
XML::Compile::SOAP::Daemon::LWPutil - LWP helper routines

=chapter SYNOPSIS
=chapter DESCRIPTION
=cut

our @EXPORT = qw(
    lwp_action_from_header
    lwp_add_header
    lwp_handle_connection
    lwp_make_response
    lwp_run_request
    lwp_wsdl_response
);

use Log::Report 'xml-compile-soap-daemon';
use LWP;
use HTTP::Status;
use XML::Compile::SOAP::Util ':daemon';

sub lwp_add_header($$);
sub lwp_handle_connection($@);
sub lwp_run_request($$;$);
sub lwp_make_response($$$$);
sub lwp_action_from_header($);

=chapter FUNCTIONS
=cut

=function lwp_add_header FIELD, CONTENT, ...
=cut

our @default_headers;
BEGIN
{   foreach my $pkg (qw/XML::Compile XML::Compile::SOAP
        XML::Compile::SOAP::Daemon XML::LibXML LWP/)
    {   no strict 'refs';
        my $version = ${"${pkg}::VERSION"} || 'undef';
        (my $field = "X-$pkg-Version") =~ s/\:\:/-/g;
        push @default_headers, $field => $version;
    }
}

sub lwp_add_header($$)
{   push @default_headers, @_;
}

=function lwp_wsdl_response [WSDLFILE|RESPONSE]
Set the result of WSDL query responses, either to a response which
is created internally containing WSDLFILE, or to an already complete
RESPONSE object (M<HTTP::Response>).  The response object is returned.
=cut

my $wsdl_response;
sub lwp_wsdl_response(;$)
{   @_ or return $wsdl_response;

    my $file = shift;
    $file && !ref $file
        or return $wsdl_response = $file;

    local *SRC;
    open SRC, '<:raw', $file
        or fault __x"cannot read wsdl file {file}", file => $file;
    local $/;
    my $spec = <SRC>;
    close SRC;

    $wsdl_response = HTTP::Response->new
      ( RC_OK, "WSDL specification"
      , [ @default_headers
        , "Content-Type" => 'application/wsdl+xml; charset="utf-8"'
        ]
      , $spec
      );
}
    
=function lwp_handle_connection CONNECTION, OPTIONS
=cut

sub lwp_handle_connection($@)
{   my ($connection, %args) = @_;
    my $expires  = $args{expires};
    my $maxmsgs  = $args{maxmsgs};
    my $reqbonus = $args{reqbonus};

    local $SIG{ALRM} = sub { die "timeout\n" };

    my $timeleft;
    while(($timeleft = $expires - time) > 0.01)
    {   alarm $timeleft if $timeleft;
        my $request  = $connection->get_request;
        alarm 0;
        $request or last;

        my $response = lwp_run_request $request, $args{handler}, $connection;
        $connection->force_last_request if $maxmsgs==1;
        $connection->send_response($response);

        --$maxmsgs or last;
        $expires += $reqbonus;
    }
}

=function lwp_run_request REQUEST, HANDLER, [CONNECTION]
Handle one REQUEST (M<HTTP::Request> object), which was received from
the CLIENT (string).  When the request has been received, the HANDLER
is called. With that result, a response message is composed.
=cut

sub lwp_run_request($$;$)
{   my ($request, $handler, $connection) = @_;

#   my $client   = $connection->peerhost;
    return $wsdl_response
        if $wsdl_response
        && $request->method eq 'GET'
        && $request->uri->path_query =~ m! \? WSDL $ !x;

    if($request->method !~ m/^(?:M-)?POST/ )
    {   return lwp_make_response $request
          , RC_METHOD_NOT_ALLOWED
          , 'only POST or M-POST'
          , "attempt to connect via ".$request->method;
    }

    my $media    = $request->content_type || 'text/plain';
    $media =~ m{[/+]xml$}i
        or return lwp_make_response $request
          , RC_NOT_ACCEPTABLE
          , 'required is XML'
          , "content-type seems to be $media, must be some XML";

    my $action   = lwp_action_from_header $request;
    my $ct       = $request->header('Content-Type');
    my $charset  = $ct =~ m/\;\s*type\=(["']?)([\w-]*)\1/ ? $2: 'utf-8';
    my $xmlin    = $request->decoded_content(charset => $charset, ref => 1);

    my ($status, $msg, $out) = $handler->($xmlin, $request, $action);

    lwp_make_response $request, $status, $msg, $out;
}

=function lwp_make_response REQUEST, RC, MSG, BODY
=cut

sub lwp_make_response($$$$)
{   my ($request, $status, $msg, $body) = @_;

    my $response = HTTP::Response->new($status, $msg);
    $response->header(@default_headers);
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

=function lwp_action_from_header REQUEST
Collect the soap action URI from the request, with C<undef> on failure.
Officially, the "SOAPAction" has no other purpose than the ability to
route messages over HTTP: it should not be linked to the portname of
the message (although it often can).
=cut

sub lwp_action_from_header($)
{   my ($request) = @_;

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
    :                               $action;
}

1;

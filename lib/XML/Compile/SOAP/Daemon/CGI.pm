use warnings;
use strict;

package XML::Compile::SOAP::Daemon::CGI;
use base 'XML::Compile::SOAP::Daemon';

our @ISA;

use Log::Report 'xml-compile-soap-daemon';
use CGI 3.53, ':cgi';
use Encode;

# do not depend on LWP
use constant
  { RC_OK                 => 200
  , RC_METHOD_NOT_ALLOWED => 405
  , RC_NOT_ACCEPTABLE     => 406
  };

=chapter NAME
XML::Compile::SOAP::Daemon::CGI - CGI based server

=chapter SYNOPSIS
 #### have a look in the examples directory!
 use XML::Compile::SOAP::Daemon::CGI;
 my $daemon = XML::Compile::SOAP::Daemon::CGI->new;

 # initialize definitions from WSDL
 my $wsdl    = XML::Compile::WSDL11->new(...);
 $wsdl->importDefinitions(...); # more schemas
 $daemon->operationsFromWSDL($wsdl, callbacks => ...);

 # per connected client
 my $query = CGI->new;
 $daemon->runCgiRequest(query => $query);

=chapter DESCRIPTION
This module handles the exchange of SOAP messages via Apache, using
mod_perl and the popular Perl module M<CGI>.  Have a look at the
F<examples/> directory, contained in the C<XML-Compile-SOAP-Daemon>
distribution.

This abstraction level of the object (code in this pm file) is not
concerned with parsing or composing XML, but only worries about the
HTTP transport specifics of SOAP messages.

=chapter METHODS

=section Constructors

=c_method new OPTIONS
=cut

#--------------------

=section Running the server

=method runCgiRequest OPTIONS

=option  query <CGI object>
=default query <created internally>

=option  postprocess CODE
=default postprocess C<undef>
When defined, the CODE will get called with a HASH (containing OPTIONS
and other compile information), a HASH of headers (which you may change),
the HTTP return code, and a reference to the message body (which may be
changed as well).

Be warned that the message body must be considered as bytes, so not
as Latin1 or utf-8 string.  You may wish to add or remove bytes. The
Content-Length will be added to the headers after the call.

=cut

sub runCgiRequest(@) {shift->run(@_)}

=method run OPTIONS
Used by M<runCgiRequest()> to process a connection. Not to be called
directly.

=method process OPTIONS
Process the content of a single message. Not to be called directly.
=cut

# called by SUPER::run()
sub _run($;$)
{   my ($self, $args, $test_cgi) = @_;

    my $q      = $test_cgi || $args->{query} || CGI->new;
    my $method = $ENV{REQUEST_METHOD} || 'POST';
    my $ct     = $ENV{CONTENT_TYPE}   || 'text/plain';
    $ct =~ s/\;\s.*//;

    return $self->sendWsdl($q)
        if $method eq 'GET' && url =~ m/ \? WSDL $ /x;

    my ($rc, $msg, $err, $mime, $bytes);
    if($method ne 'POST' && $method ne 'M-POST')
    {   ($rc, $msg) = (RC_METHOD_NOT_ALLOWED, 'only POST or M-POST');
        $err = 'attempt to connect via GET';
    }
    elsif($ct !~ m/\bxml\b/)
    {   ($rc, $msg) = (RC_NOT_ACCEPTABLE, 'required is XML');
        $err = 'content-type seems to be text/plain, must be some XML';
    }
    else
    {   my $charset = $q->charset || 'ascii';
        my $xmlin   = decode $charset, $q->param('POSTDATA');
        my $action  = $ENV{HTTP_SOAPACTION} || $ENV{SOAPACTION} || '';
        $action     =~ s/["'\s]//g;   # sometimes illegal quoting and blanks
        ($rc, $msg, my $xmlout) = $self->process(\$xmlin, $q, $action);

        if(UNIVERSAL::isa($xmlout, 'XML::LibXML::Document'))
        {   $bytes = $xmlout->toString($rc == RC_OK ? 0 : 1);
            $mime  = 'text/xml; charset="utf-8"';
        }
        else
        {   $err   = $xmlout;
        }
    }

    unless($bytes)
    {   $bytes = "[$rc] $err\n";
        $mime  = 'text/plain';
    }

    my %headers =
      ( -status  => "$rc $msg"
      , -type    => $mime
      , -charset => 'utf-8'
      , -nph     => 1
      );

    if(my $pp = $args->{postprocess})
    {   $pp->($args, \%headers, $rc, \$bytes);
    }

    $headers{-Content_length} = length $bytes;
    print $q->header(\%headers);
    print $bytes;
}

sub setWsdlResponse($)
{   my ($self, $fn) = @_;
    $fn or return;
    local *WSDL;
    open WSDL, '<:raw', $fn
        or fault __x"cannot read WSDL from {file}", file => $fn;
    local $/;
    $self->{wsdl_data} = <WSDL>;
    close WSDL;
}

sub sendWsdl($)
{   my ($self, $q) = @_;

    print $q->header
      ( -status  => RC_OK.' WSDL specification'
      , -type    => 'application/wsdl+xml'
      , -charset => 'utf-8'
      , -nph     => 1

      , -Content_length => length($self->{wsdl_data})
      );

    print $self->{wsdl_data};
}
    
#-----------------------------

=chapter DETAILS

=section How to use the CGI module

The code and documentation for this module was contributed by Patrick
Powell in December 2010. Both have seen major changes since.

Go to the F<examples/mod_perl/> directory which is included in
the distribution of this module, M<XML::Compile::SOAP::Daemon>.
There you find a README describing the process.

=cut

1;

# This code is part of distribution XML-Compile-SOAP-Daemon.  Meta-POD
# processed with OODoc into POD and HTML manual-pages.  See README.md
# Copyright Mark Overmeer.  Licensed under the same terms as Perl itself.

package XML::Compile::SOAP::Daemon::CGI;
use parent 'XML::Compile::SOAP::Daemon';

use warnings;
use strict;

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

=c_method new %options
=cut

#--------------------
=section Running the server

=method runCgiRequest %options

=option  query <CGI object>
=default query <created internally>

=option  postprocess CODE
=default postprocess C<undef>
When defined, the CODE will get called with a HASH (containing %options
and other compile information), a HASH of headers (which you may change),
the HTTP return code, and a reference to the message body (which may be
changed as well).

Be warned that the message body must be considered as bytes, so not
as Latin1 or utf-8 string.  You may wish to add or remove bytes. The
Content-Length will be added to the headers after the call.

=cut

sub runCgiRequest(@) {shift->run(@_)}

=method run %options
Used by M<runCgiRequest()> to process a connection. Not to be called
directly.

=method process %options
Process the content of a single message. Not to be called directly.

=option  nph BOOLEAN
=default nph <true>
For FCGI, you probably need to set this to a false value.
=cut

# called by SUPER::run()
sub _run($;$)
{   my ($self, $args, $test_cgi) = @_;

    my $q      = $test_cgi || $args->{query} || CGI->new;
    my $method = $ENV{REQUEST_METHOD} || 'POST';
    my $qs     = $ENV{QUERY_STRING}   || '';
    my $ct     = $ENV{CONTENT_TYPE}   || 'text/plain';
    $ct =~ s/\;\s.*//;

    return $self->sendWsdl($q)
        if $method eq 'GET' && uc($qs) eq 'WSDL';

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
      , -nph     => ($args->{nph} ? 1 : 0)
      );

    if(my $pp = $args->{postprocess})
    {   $pp->($args, \%headers, $rc, \$bytes);
    }

    $headers{-Content_length} = length $bytes;
    print $q->header(\%headers);
    print $bytes;
}

sub setWsdlResponse($;$)
{   my ($self, $fn, $ft) = @_;
    $fn or return;
    local *WSDL;
    open WSDL, '<:raw', $fn
        or fault __x"cannot read WSDL from {file}", file => $fn;
    local $/;
    $self->{wsdl_data} = <WSDL>;
    $self->{wsdl_type} = $ft || 'application/wsdl+xml';
    close WSDL;
}

sub sendWsdl($)
{   my ($self, $q) = @_;

    print $q->header
      ( -status  => RC_OK.' WSDL specification'
      , -type    => $self->{wsdl_type}
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

=section Configuring Apache

Your virtual host may need something like this:

    Options     Indexes FollowSymLinks MultiViews
    PerlHandler ModPerl::Registry
    PerlOptions -ParseHeaders
    AddHandler  perl-script .cgi
    Options     +ExecCGI
    Order       allow,deny
    Allow       from all

=cut

1;

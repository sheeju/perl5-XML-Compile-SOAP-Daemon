# This code is part of distribution XML-Compile-SOAP-Daemon.  Meta-POD
# processed with OODoc into POD and HTML manual-pages.  See README.md
# Copyright Mark Overmeer.  Licensed under the same terms as Perl itself.

package XML::Compile::SOAP::Daemon::PSGI;
use parent 'XML::Compile::SOAP::Daemon', 'Plack::Component';

use warnings;
use strict;

use Log::Report 'xml-compile-soap-daemon';

use Encode;
use Plack::Request;
use Plack::Response;

=chapter NAME

XML::Compile::SOAP::Daemon::PSGI - PSGI based application

=chapter SYNOPSIS

 #### have a look in the examples directory!
 use XML::Compile::SOAP::Daemon::PSGI;
 my $daemon = XML::Compile::SOAP::Daemon::PSGI->new;

 # initialize definitions from WSDL
 my $wsdl    = XML::Compile::WSDL11->new(...);
 $wsdl->importDefinitions(...); # more schemas
 $daemon->operationsFromWSDL($wsdl, callbacks => ...);

 # generate PSGI application
 my $app = $daemon->to_app;
 $app;

=chapter DESCRIPTION

This module handles the exchange of SOAP messages via PSGI stack,
using Plack toolkit. This module was contributed by Piotr Roszatycki.

This abstraction level of the object (code in this pm file) is not
concerned with parsing or composing XML, but only worries about the
HTTP transport specifics of SOAP messages.

=chapter METHODS
=cut

use constant
  { RC_OK                 => 200
  , RC_METHOD_NOT_ALLOWED => 405
  , RC_NOT_ACCEPTABLE     => 406
  , RC_SERVER_ERROR       => 500
  };

#--------------------

=c_method new %options

=option  preprocess CODE
=default preprocess C<undef>
When defined, the CODE will get called with a M<Plack::Request> object
before processing SOAP message.

=option  postprocess CODE
=default postprocess C<undef>
When defined, the CODE will get called with a M<Plack::Request> and
M<Plack::Response> objects after processing SOAP message.

=cut

sub init($)
{   my ($self, $args) = @_;
    $self->SUPER::init($args);
    $self->_init($args);
    $self;
}

#------------------------------
=section Running the server

=method to_app
Converts the server into a PSGI C<$app>.

=method run %options
The same as B<to_app> but accepts additional B<preprocess> and
B<postprocess> options.
=cut

sub run(@)
{   my ($self, $args) = @_;
    $self->_init($args);
    $self->to_app;
}

sub _init($)
{   my ($self, $args) = @_;
    $self->{preprocess}  = $args->{preprocess};
    $self->{postprocess} = $args->{postprocess};
    $self;
}

=method call $env
Process the content of a single message. Not to be called directly.
=cut

# PSGI request handler
sub call($)
{   my ($self, $env) = @_;
    my $res = eval { $self->_call($env) };
    $res ||= Plack::Response->new
      ( RC_SERVER_ERROR
      , [Content_Type => 'text/plain']
      , [$@]
      );
    $res->finalize;
}

sub _call($;$)
{   my ($self, $env, $test_env) = @_;

    notice __x"WSA module loaded, but not used"
        if XML::Compile::SOAP::WSA->can('new') && !keys %{$self->{wsa_input}};
    $self->{wsa_input_rev}  = +{ reverse %{$self->{wsa_input}} };

    my $req = Plack::Request->new($test_env || $env);

    return $self->sendWsdl($req)
        if $req->method eq 'GET' && uc($req->uri->query || '') eq 'WSDL';

    if(my $pp = $self->{preprocess})
    {   $pp->($req);
    }

    my $method = $req->method;
    my $ct     = $req->content_type || 'text/plain';
    $ct =~ s/\;\s.*//;

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
    {   my $charset = $req->headers->content_type_charset || 'ascii';
        my $xmlin   = decode $charset, $req->content;
        my $action  = $req->header('SOAPAction') || '';
        $action     =~ s/["'\s]//g;   # sometimes illegal quoting and blanks "
        ($rc, $msg, my $xmlout) = $self->process(\$xmlin, $req, $action);

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

    my $res = $req->new_response($rc,
      { Warning      => "199 $msg"
      , Content_Type => $mime
      }, $bytes);

    if(my $pp = $self->{postprocess})
    {   $pp->($req, $res);
    }

    $res->content_length(length $bytes);
    $res;
}

sub setWsdlResponse($;$)
{   my ($self, $fn, $ft) = @_;
    local *WSDL;
    open WSDL, '<:raw', $fn
        or fault __x"cannot read WSDL from {file}", file => $fn;
    local $/;
    $self->{wsdl_data} = <WSDL>;
    $self->{wsdl_type} = $ft || 'application/wsdl+xml';
    close WSDL;
}

sub sendWsdl($)
{   my ($self, $req) = @_;

    my $res = $req->new_response(RC_OK,
      { Warning        => '199 WSDL specification'
      , Content_Type   => $self->{wsdl_type}.'; charset=utf-8'
      , Content_Length => length($self->{wsdl_data})
      }, $self->{wsdl_data});

    $res;
}

#-----------------------------
=chapter DETAILS

=section How to use the PSGI module

The code and documentation for this module was contributed by Piotr
Roszatycki in March 2012.

Go to the F<examples/mod_perl/> directory which is included in the
distribution of this module, M<XML::Compile::SOAP::Daemon> There you
find a README describing the process.

=section Using Basic Authenication

[example contributed by Emeline Thibault]

  my $daemon = XML::Compile::SOAP::Daemon::PSGI->new(...);
  $daemon->operationsFromWSDL($wsdl, callbacks => {...});

  use Plack::Middleware::Auth::Basic;
  my %map = ( admin => "password" );
  builder {
    enable "Auth::Basic", authenticator => \&cb;
    $daemon;
  };

  sub cb {
    my ( $username, $password ) = @_;
    return $map{$username} && $password eq $map{$username};
  }

=cut

1;



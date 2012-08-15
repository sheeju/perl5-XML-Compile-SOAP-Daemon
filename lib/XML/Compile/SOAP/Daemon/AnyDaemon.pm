use warnings;
use strict;

package XML::Compile::SOAP::Daemon::AnyDaemon;

# Any::Daemon at least version 0.13
use base 'XML::Compile::SOAP::Daemon', 'Any::Daemon';

use Log::Report 'xml-compile-soap-daemon';

use Time::HiRes       qw/time alarm/;
use Socket            qw/SOMAXCONN/;
use IO::Socket::INET  ();

use XML::Compile::SOAP::Util  qw/:daemon/;
use XML::Compile::SOAP::Daemon::LWPutil;

=chapter NAME
XML::Compile::SOAP::Daemon::AnyDaemon - SOAP server based on Any::Daemon

=chapter SYNOPSIS
 #### have a look in the examples directory!
 use XML::Compile::SOAP::Daemon::AnyDaemon;
 use XML::Compile::SOAP11;
 use XML::Compile::SOAP::WSA;  # optional

 my $daemon  = XML::Compile::SOAP::Daemon::AnyDaemon->new;

 # daemon definitions from WSDL
 my $wsdl    = XML::Compile::WSDL11->new(...);
 $wsdl->importDefinitions(...); # more schemas
 $daemon->operationsFromWSDL($wsdl, callbacks => ...);

 # daemon definitions added manually (when no WSDL)
 my $soap11  = XML::Compile::SOAP11::Server->new(schemas => $wsdl->schemas);
 my $handler = $soap11->compileHandler(...);
 $daemon->addHandler('getInfo', $soap11, $handler);

 # see what is defined:
 $daemon->printIndex;

 # finally, run the server.  This never returns.
 $daemon->run(@daemon_options);
 
=chapter DESCRIPTION
This module handles the exchange of SOAP messages over HTTP with
M<Any::Daemon> as daemon implementation. It is a simple pre-forked
daemon, much easier than the M<Net::Server> implementations.

We use M<HTTP::Daemon> as HTTP-connection implementation. The
M<HTTP::Request> and M<HTTP::Response> objects (provided
by C<HTTP-Message>) are handled via functions provided by
M<XML::Compile::SOAP::Daemon::LWPutil>.

This abstraction level of the object (code in this pm file) is not
concerned with parsing or composing XML, but only worries about the
HTTP transport specifics of SOAP messages.  The processing of the SOAP
message is handled by the M<XML::Compile::SOAP::Daemon> base-class.

The server is as flexible as possible: accept M-POST (HTTP Extension
Framework) and POST (standard HTTP) for any message.  It can be used
for any SOAP1.1 and SOAP1.2 mixture.  Although SOAP1.2 itself is
not implemented yet.

=chapter METHODS

=c_method new OPTIONS
Create the server handler, which extends some class which implements
a M<Net::Server> daemon.

As OPTIONS, you can pass everything accepted by M<Any::Daemon::new()>,
like C<pid_file>, C<user>, C<group>, and C<workdir>,
=cut

sub new($%)
{   my ($class, %args) = @_;
    my $self = Any::Daemon->new(%args);
    (bless $self, $class)->init(\%args);  # $ISA[0] branch only
}

sub setWsdlResponse($)
{   my ($self, $fn) = @_;
    trace "setting wsdl response to $fn";
    lwp_wsdl_response $fn;
}

#-----------------------
=section Running the server

=method run OPTIONS

=option  server_name   STRING
=default server_name   C<undef>

=option  client_timeout SECONDS
=default client_timeout 30
The maximum time a connection may exist, before being terminated.

=option  client_maxreq  NUMBER
=default client_maxreq  100
Maximum number of requests per connection.

=option  client_reqbonus SECONDS
=default client_reqbonus 0
Time to add to the timeout as bonus per handled client request. Fast
clients get more time over slow clients, more time to reach their
maximum number of requests.

=option  postprocess CODE
=default postprocess C<undef>
See the section about this option in the DETAILS chapter of the
M<XML::Compile::SOAP::Daemon::LWPutil> manual-page.

=option  max_childs  INTEGER
=default max_childs  10

=option  background  BOOLEAN
=default background  <true>

=option  socket SOCKET
=default socket C<undef>
Pass your own socket, in stead of having one created for you. The SOCKET
must be an C<IO::Socket::INET> (or compatible like M<IO::Socket::SSL> and
M<IO::Socket::IP>)

=option  host STRING
=default host C<undef>
Ignored when a socket is provided, otherwise required.

=option  port INTEGER  
=default port C<undef>
Ignored when a socket is provided, otherwise required.

=option  listen INTEGER
=default listen SOMAXCONN
Ignored when a socket is provided.

=option  child_init CODE
=default child_init C<undef>
This CODE reference will get called by each child which gets started,
before the "accept" waiting starts.  Ideal moment to start your
database-connection.
=cut

sub _run($)
{   my ($self, $args) = @_;
    my $name = $args->{server_name} || 'soap server';
    lwp_add_header
       'X-Any-Daemon-Version' => $Any::Daemon::VERSION
      , Server => $name;

    my $socket = $args->{socket};
    unless($socket)
    {   my $host = $args->{host} or error "run() requires host";
        my $port = $args->{port} or error "run() requires port";

        $socket  = IO::Socket::INET->new
          ( LocalHost => $host
          , LocalPort => $port
          , Listen    => ($args->{listen} || SOMAXCONN)
          , Reuse     => 1
          ) or fault __x"cannot create socket at {interface}"
            , interface => "$host:$port";

        info __x"created socket at {interface}", interface => "$host:$port";
    }
    $self->{XCSDA_socket}    = $socket;
    lwp_socket_init $socket;

    $self->{XCSDA_conn_opts} =
      { client_timeout  => ($args->{client_timeout}  ||  30)
      , client_maxreq   => ($args->{client_maxreq}   || 100)
      , client_reqbonus => ($args->{client_reqbonus} ||   0)
      , postprocess     => $args->{postprocess}
      };

    my $child_init = $args->{child_init} || sub {};
    my $child_task = sub {$child_init->($self); $self->accept_connections};

    $self->Any::Daemon::run
      ( child_task => $child_task
      , max_childs => ($args->{max_childs} || 10)
      , background => (exists $args->{background} ? $args->{background} : 1)
      );
}

sub accept_connections()
{   my $self   = shift;
    my $socket = $self->{XCSDA_socket};

    while(my $client = $socket->accept)
    {   info __x"new client {remote}", remote => $client->peerhost;
        $self->handle_connection(lwp_http11_connection $self, $client);
        $client->close;
    }
}

sub handle_connection($)
{   my ($self, $connection) = @_;
    my $conn_opts = $self->{XCSDA_conn_opts};
    eval {
        lwp_handle_connection $connection
          , %$conn_opts
          , expires  => time() + $conn_opts->{client_timeout}
          , handler  => sub {$self->process(@_)}
    };
    info __x"connection ended with force; {error}", error => $@
        if $@;
    1;
}

sub url() { "url replacement not yet implemented" }
sub product_tokens() { shift->{prop}{name} }

#-----------------------------

=chapter DETAILS

=section AnyDaemon with SSL

First, create certificates and let them be signed by a CA (or yourself)
See F<http://devsec.org/info/ssl-cert.html> to understand this.

  # generate secret private key
  openssl genrsa -out privkey.pem 1024

  # create a "certification request" (CSR)
  openssl req -new -key privkey.pem -out certreq.csr

  # send the CSR to the Certification Authority or self-sign:
  openssl x509 -req -days 3650 -in certreq.csr -signkey privkey.pem -out newcert.pem

  # publish server certificate
  ( openssl x509 -in newcert.pem; cat privkey.pem ) > server.pem
  ln -s server.pem `openssl x509 -hash -noout -in server.pem`.0   # dot-zero

Assuming that the certificates are in 'certs/', the program looks like this:

  use Log::Report;
  use XML::Compile::SOAP::Daemon::AnyDaemon;
  use XML::Compile::WSDL11;
  use IO::Socket::SSL       'SSL_VERIFY_NONE';
  use IO::Socket            'SOMAXCONN';

  my $daemon = XML::Compile::SOAP::Daemon::AnyDaemon->new;
  my $wsdl   = XML::Compile::WSDL11->new($wsdl);

  my %handlers = ();
  $daemon->operationsFromWSDL($wsdl, callbacks => \%handlers);

  my $socket = IO::Socket::SSL->new
   ( LocalHost  => 'localhost'
   , LocalPort  => 4444
   , Listen     => SOMAXCONN
   , Reuse      => 1
   , SSL_server => 1
   , SSL_verify_mode => SSL_VERIFY_NONE
   , SSL_key_file    => 'certs/privkey.pem'
   , SSL_cert_file   => 'certs/server.pem'
   ) or error __x"cannot create socket at {interface}: {err}"
         , interface => "$host:$port"
         , err => IO::Socket::SSL::errstr();

  $daemon->run
   ( name       => basename($0)
   , max_childs => 1
   , socket     => $socket
   , child_init => \&for_instance_connect_to_db
   )
=cut

1;

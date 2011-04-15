use warnings;
use strict;

package XML::Compile::SOAP::Daemon::NetServer;
use base 'XML::Compile::SOAP::Daemon';

our @ISA;
use Log::Report 'xml-compile-soap-daemon';

use HTTP::Daemon              ();
use Time::HiRes               qw/time alarm/;
use XML::Compile::SOAP::Util  qw/:daemon/;
use XML::Compile::SOAP::Daemon::LWPutil;

# Net::Server error levels to Log::Report levels
my @levelToReason = qw/ERROR WARNING NOTICE INFO TRACE/;

=chapter NAME
XML::Compile::SOAP::Daemon::NetServer - SOAP server based on Net::Server

=chapter SYNOPSIS
 #### have a look in the examples directory!
 use XML::Compile::SOAP::Daemon::NetServer;
 use XML::Compile::SOAP11;
 use XML::Compile::SOAP::WSA;  # optional

 # Be warned that the daemon will be Net::Server based, which
 # consumes command-line arguments! "local @ARGV;" maybe useful
 my $daemon  = XML::Compile::SOAP::Daemon::NetServer->new;

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
M<Net::Server> as daemon implementation, It uses M<HTTP::Request> and
M<HTTP::Response> object provided by M<LWP>, via functions provided by
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
a M<Net::Server> daemon. Any daemon configuration parameter should
be passed with M<run()>.  This is a little tricky.  Read below in the
L</Configuration options> section.

=option  based_on any M<Net::Server> OBJECT|CLASS
=default based_on M<Net::Server::PreFork>
You may pass your own M<Net::Server> compatible daemon, if you feel a need
to initialize it or prefer an other one.  Preferrably, pass configuration
settings to M<run()>. You may also specify any M<Net::Server> compatible
CLASS name.

=cut

sub new($%)
{   my ($class, %args) = @_;
    my $daemon = $args{based_on} || 'Net::Server::PreFork';

    my $self;
    if(ref $daemon)
    {   $self = $daemon;
    }
    else
    {   eval "require $daemon";
        $@ and error __x"failed to compile Net::Server class {class}, {error}"
           , class => $daemon, error => $@;
        $self = $daemon->new(%args);
    }

    $self->{based_on} = ref $daemon || $daemon;
    $daemon->isa('Net::Server')
        or error __x"The daemon is not a Net::Server, but {class}"
             , class => $self->{based_on};

    # Beautiful Perl
    push @ISA, $self->{based_on};
    (bless $self, $class)->init(\%args);  # $ISA[0] branch only
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
    my %mydef =
     ( # changed defaults
       setsid => 1, background => 1, log_file => 'Log::Report'

       # make in-code defaults explicit, Net::Server 0.97
       # see http://rt.cpan.org//Ticket/Display.html?id=32226
     , log_level => 2, syslog_ident => 'net_server', syslog_logsock => 'unix'
     , syslog_facility => 'daemon', syslog_logopt => 'pid'

     , client_timeout => 30, client_maxreq => 100
     , client_reqbonus => 0, name => 'soap daemon'
     );
    @$def{keys %mydef} = values %mydef;
    $def;
}

sub post_configure()
{   my $self = shift;
    my $prop = $self->{server};

    # Change the way messages are logged

    my $loglevel = $prop->{log_level};
    my $reasons  = ($levelToReason[$loglevel] || 'NOTICE') . '-';

    my $logger   = delete $prop->{log_file};
    if($logger eq 'Log::Report')
    {   # dispatching already initialized
    }
    elsif($logger eq 'Sys::Syslog')
    {   dispatcher SYSLOG => 'default'
          , accept    => $reasons
          , identity  => $prop->{syslog_ident}
          , logsocket => $prop->{syslog_logsock}
          , facility  => $prop->{syslog_facility}
          , flags     => $prop->{syslog_logopt}
    }
    else
    {   dispatcher FILE => 'default', to => $logger;
    }

    $self->SUPER::post_configure;
}

sub setWsdlResponse($)
{   my ($self, $fn) = @_;
    trace "setting wsdl response to $fn";
    lwp_wsdl_response $fn;
}

# Overrule Net::Server's log() to translate it into Log::Report calls
sub log($$@)
{   my ($self, $level, $msg) = (shift, shift, shift);
    $msg = sprintf $msg, @_ if @_;
    $msg =~ s/\n$//g;  # some log lines have a trailing newline

    my $reason = $levelToReason[$level] or return;
    report $reason => $msg;
}

# use Log::Report for hooks
sub write_to_log_hook { panic "write_to_log_hook cannot be used" }

=section Running the server

=method run OPTIONS
See M<Net::Server::run()>, but the OPTIONS are passed as list, not
as HASH.
=cut

sub _run($)
{   my ($self, $args) = @_;
    delete $args->{log_file};      # Net::Server should not mess with my preps
    $args->{no_client_stdout} = 1; # it's a daemon, you know
    lwp_add_header Server => $self->{prop}{name};

    $ISA[1]->can('run')->($self, $args);    # never returns
}

sub process_request()
{   my $self = shift;
    my $prop = $self->{server};

eval {
    # Merge Net::Server behavior with HTTP::Daemon
    # Now, our connection will become a HTTP::Daemon connection
    my $old_class  = ref $prop->{client};
    my $connection = bless $prop->{client}, 'HTTP::Daemon::ClientConn';
    ${*$connection}{httpd_daemon} = $self;

    eval {
        lwp_handle_connection $connection
          , expires  => time() + $prop->{client_timeout}
          , maxmsgs  => $prop->{client_maxreq}
          , reqbonus => $prop->{client_reqbonus}
          , handler  => sub {$self->process(@_)}
    };

    info __x"connection ended with force; {error}", error => $@
        if $@;

    # Our connection becomes as Net::Server::Proto::TCP again
    bless $prop->{client}, $old_class;
 };
 alert $@ if $@;
    1;
}

sub url() { "url replacement not yet implemented" }
sub product_tokens() { shift->{prop}{name} }

#-----------------------------

=chapter DETAILS

=section Configuration options

This module will wrap any kind of M<Net::Server>, for instance a
M<Net::Server::PreFork>.  It depends on the type of C<Net::Server>
you specify (see M<new(based_on)>) which configuration options are
available on the command-line, in a configuration file, or with M<run()>.
Each daemon extension implementation will add some configuration options
as well.

Any C<XML::Compile::SOAP::Daemon::NetServer> object will have the following
additional configuration options:

  Key             Value             Default
  client_timeout  integer seconds   30
  client_maxreq   integer           100
  client_reqbonus integer seconds   0
  name            string            "soap daemon"

Some general configuration options of Net::Server have a
different default.  See also the next section about logging.

  Key             Value             New default
  setsid          boolean           true
  background      boolean           true

For each client, we like to have a reset of the connection after some
time, for two reasons: perl processes are usually leaking memory a bit
so should not live for ever, and you can experience denial of service
attacks.  The C<client_timeout> value details the number of seconds
a connection may live, but that will be increase by C<client_reqbonus>
for every received message.  In any case, after C<client_maxreq> messages
were handled, the connection will be terminated.

The C<name> is included in the reply messages.

=subsection logging

An attempt is made to merge XML::Compile's M<Log::Report> and M<Net::Server>
log configuration.  By hijacking the C<log()> method, all Net::Server
internal errors are dispatched over the Log::Report framework.  Log levels
are translated into report reasons: 0=ERROR, 1=WARNING, 2=NOTICE, 3=INFO,
4=TRACE.

When you specify C<Sys::Syslog> or a filename, default dispatchers of type
SYSLOG resp FILE are created for you.  When the C<log_file> type is set to
C<Log::Report>, you have much more control over the process, but all log
related configuration options will get ignored.  In that case, you must
have initialized the dispatcher framework the way Log::Report is doing
it: before the daemon is initiated. See M<Log::Report::dispatcher()>.

  Key          Value                            Default
  log_file     filename|Sys::Syslog|Log::Report Log::Report
  log_level    0..4 | REASON                    2 (NOTICE)


=cut

1;

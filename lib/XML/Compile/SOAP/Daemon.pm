use warnings;
use strict;

package XML::Compile::SOAP::Daemon;
our @ISA;   # filled-in at new().

use Log::Report 'xml-compile-soap-daemon', syntax => 'SHORT';
dispatcher SYSLOG => 'default';

use XML::LibXML        ();
use XML::Compile::Util qw/type_of_node/;

use List::Util         qw/first/;
use Time::HiRes        qw/time/;

# we use HTTP status definitions for each soap protocol
use HTTP::Status       qw/RC_FORBIDDEN RC_NOT_IMPLEMENTED
  RC_SEE_OTHER RC_NOT_ACCEPTABLE RC_UNPROCESSABLE_ENTITY
  RC_NOT_IMPLEMENTED RC_NOT_FOUND/;

# Net::Server error levels to Log::Report levels
my @levelToReason = qw/ERROR WARNING NOTICE INFO TRACE/;

my $parser        = XML::LibXML->new;

=chapter NAME
XML::Compile::SOAP::Daemon - SOAP accepting server

=chapter SYNOPSIS
 #### have a look in the examples directory!
 use XML::Compile::SOAP::HTTPDaemon;
 use XML::Compile::SOAP11;
 use XML::Compile::SOAP::WSA;  # optional

 # Be warned that the daemon will be Net::Server based, which consumes
 # command-line arguments!
 my $daemon  = XML::Compile::SOAP::HTTPDaemon->new;

 # daemon definitions from WSDL
 my $wsdl    = XML::Compile::WSDL11->new(...);
 $wsdl->importDefinitions(...); # more schemas
 $daemon->operationsFromWSDL($wsdl, callbacks => ...);

 # daemon definitions added manually
 my $soap11  = XML::Compile::SOAP11::Server->new(schemas => $wsdl->schemas);
 my $handler = $soap11->compileHandler(...);
 $daemon->addHandler('getInfo', $soap11, $handler);

 # see what is defined:
 $daemon->printIndex;

 # finally, run the server.  This never returns.
 $daemon->run(...daemon options...);

=chapter DESCRIPTION

This base class implements the common needs between various types of
SOAP daemons.  As daemon type, you can use any kind of M<Net::Server>
implementation.

The following extensions are implemented on the moment: (other are not
yet planned to get implemented)

=over 4
=item .
M<XML::Compile::SOAP::HTTPDaemon>, for transport over HTTP.

=back

The daemon can handle various kinds of SOAP protocols at the same time,
when possible hidden from the user of this module.

If you have a WSDL describing your procedures, then the only thing you
have to worry about is adding callbacks for each of the defined ports.
Without WSDL, you will need to do more manually, but it is still
relatively simple to achieve.

Do not forget to take a look at the extensive example, enclosed in the
M<XML::Compile::SOAP::Daemon> distribution package.  It is really worth
the time.

=cut

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
     );
   @$def{keys %mydef} = values %mydef;
   $def;
}

#-------------------------------------

=chapter METHODS

=section Constructors

=c_method new OPTIONS
Create the server handler, which extends some class which implements
a M<Net::Server>.

Any daemon configuration parameter should be passed with M<run()>.  This
is a little tricky.  Read below in the L</Configuration options> section.

=option  output_charset STRING
=default output_charset 'UTF-8'
The character-set to be used for the output XML document.

=option  based_on Net::Server OBJECT|CLASS
=default based_on <internal Net::Server::PreFork>
You may pass your own M<Net::Server> compatible daemon, if you feel a need
to initialize it or prefer an other one.  Preferrably, pass configuration
settings to M<run()>.  You may also specify any M<Net::Server> compatible
CLASS name.

=option  wsa_action_input HASH|ARRAY
=default wsa_action_input {}
The keys are port names, the values are strings which are used by
clients to indicate which server operation they want to use. Often,
an WSDL contains this information in C<wsaw:Action> attributes; that
info is added to this HASH automatically.

=option  wsa_action_output HASH|ARRAY
=default wsa_action_output {}
The keys are port names, the values are strings which the server will
add to replies to the client. Often, an WSDL contains this information
in C<wsaw:Action> attributes.

=option  soap_action_input HASH|ARRAY
=default soap_action_input {}
The keys are port names, with as value the related SOAPAction header
field content (without quotes). Often, these SOAPAction fields originate
from the WSDL.

=option  accept_slow_select BOOLEAN
=default accept_slow_select <true>
Traditional SOAP does not have a simple way to find-out which operation
is being called. The only way to figure-out which operation is needed,
is by trying all defined operations... until one matches.

Later, people started to use soapAction (which was officially only
for proxies) and then the WSA header extension. Both of them make
it easy to find the right handler one on one.

Disabling C<accept_slow_select> will protect you againts various
forms of DoS-attacks, however is often not possible.
=cut

sub new(@)  # not called by HTTPDaemon
{   my ($class, %args) = @_;

    # Use a Net::Server as base object

    my $daemon = delete $args{based_on} || 'Net::Server::PreFork';
    unless(ref $daemon)
    {   eval "require $daemon";
        $@ and error __x"failed to compile Net::Server class {class}, {error}"
           , class => $daemon, error => $@;

        my %options;
        $daemon = $daemon->new;
    }

    $daemon->isa('Net::Server')
        or error __x"The daemon is not a Net::Server, but {class}"
             , class => ref $daemon;

    # Upgrade daemon, wow Perl!
    @ISA = ref $daemon;
    my $self = (bless $daemon, $class)->init(\%args);

    $self->{accept_slow_select}
      = exists $args{accept_slow_select} ? $args{accept_slow_select} : 1; 

    $self->addWsaTable(INPUT  => $args{wsa_action_input});
    $self->addWsaTable(OUTPUT => $args{wsa_action_output});
    $self->addSoapAction($args{soap_action_input});
    $self;
}

sub init($)
{   my ($self, $args) = @_;

    if(my $support = delete $args->{support_soap})
    {   # simply only load the protocol versions you want to accept.
        error __x"new(support_soap} removed in 2.00";
    }

    my @classes = XML::Compile::SOAP::Operation->registered;
    @classes   # explicit load required since 2.00
        or warning "No protocol modules loaded.  Need XML::Compile::SOAP11?";

    $self->{output_charset} = delete $args->{output_charset} || 'UTF-8';
    $self->{handler}        = {};
    $self;
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

=section Attributes

=method outputCharset
The character-set to be used for output documents.
=cut

sub outputCharset() {shift->{output_charset}}

=method addWsaTable ('INPUT'|'OUTPUT'), [HASH|PAIRS]
Map operation name onto respectively server-input or server-output
messages, used for C<wsa:Action> fields in the header. Usually, these
values are automatically taken from the WSDL (but only if the WSA
extension is loaded).
=cut

sub addWsaTable($@)
{   my ($self, $dir) = (shift, shift);
    my $h = @_==1 ? shift : { @_ };
    my $t = $dir eq 'INPUT'  ? ($self->{wsa_input}  ||= {})
          : $dir eq 'OUTPUT' ? ($self->{wsa_output} ||= {})
          : error __x("addWsaTable requires 'INPUT' or 'OUTPUT', not {got}"
              , got => $dir);

    while(my($op, $action) = each %$h) { $t->{$op} ||= $action }
    $t;
}

=method addSoapAction HASH|PAIRS
Map SOAPAction headers only operations. You do not need to map
explicitly when the info can be derived from the WSDL.
=cut

sub addSoapAction(@)
{   my $self = shift;
    my $h = @_==1 ? shift : { @_ };
    my $t = $self->{sa_input}     ||= {};
    my $r = $self->{sa_input_rev} ||= {};
    while(my($op, $action) = each %$h)
    {   $t->{$op}     ||= $action;
        $r->{$action} ||= $op;
    }
    $t;
}

=section Running the server

=method run OPTIONS
See M<Net::Server::run()>, but the OPTIONS are passed as list, not
as HASH.
=cut

sub run(@)
{   my ($self, %args) = @_;
    delete $args{log_file};      # Net::Server should not mess with my preps
    $args{no_client_stdout} = 1; # it's a daemon, you know
    $self->{wsa_input_rev}  = +{ reverse %{$self->{wsa_input}} };
    $self->SUPER::run(%args);
}

=method process CLIENT, XMLIN, REQUEST, ACTION
The XMLIN SOAP-structured message (an M<XML::LibXML::Element>,
M<XML::LibXML::Document>, or XML as string), was received from the CLIENT
(some extension specific object).

The full REQUEST is passed in, however its format depends on the
kind of server. The ACTION parameter relates to the soapAction header
field which may be available in some form.

Returned is an XML document as answer or a protocol specific ready
response object (usually an error object).
=cut

# defined by Net::Server
sub process_request(@) { panic "must be extended" }

sub process($)
{   my ($self, $input, $req, $soapaction) = @_;

    my $xmlin;
    if(ref $input eq 'SCALAR')
    {   $xmlin = try { $parser->parse_string($$input) };
        !$@ && $input
            or return $self->faultInvalidXML($@->died)
    }
    else
    {   $xmlin = $input;
    }
    
    $xmlin     = $xmlin->documentElement
        if $xmlin->isa('XML::LibXML::Document');

    my $local  = $xmlin->localName;
    $local eq 'Envelope'
        or return $self->faultNotSoapMessage(type_of_node $xmlin);

    my $envns  = $xmlin->namespaceURI || '';
    my $proto  = XML::Compile::SOAP::Operation->fromEnvelope($envns)
        or return $self->faultUnsupportedSoapVersion($envns);
    # proto is a XML::Compile::SOAP*::Operation
    my $server = $proto->serverClass;

    my $info   = XML::Compile::SOAP->messageStructure($xmlin);
    my $version  = $info->{soap_version} = $proto->version;
    my $handlers = $self->{handler}{$version} || {};

    # Try to resolve operation via WSA
    my $wsa_in   = $self->{wsa_input_rev};
    if(my $wsa_action = $info->{wsa_action})
    {   if(my $name = $wsa_in->{$wsa_action})
        {   my $handler = $handlers->{$name};
            local $info->{selected_by} = 'wsa-action';
            my ($rc, $msg, $xmlout) = $handler->($name, $xmlin, $info);
            if($xmlout)
            {   trace "data ready for $version $name, via wsa $wsa_action";
                return ($rc, $msg, $xmlout);
            }
        }
    }

    # Try to resolve operation via soapAction
    my $sa = $self->{sa_input_rev};
    if(defined $soapaction && $soapaction =~ m/^\s*(["'])?(.+)\1\s*$/)
    {   if(my $name = $sa->{$1})
        {   my $handler = $handlers->{$name};
            local $info->{selected_by} = 'soap-action';
            my ($rc, $msg, $xmlout) = $handler->($name, $xmlin, $info);
            if($xmlout)
            {   trace "data ready for $version $name, via sa $soapaction";
                return ($rc, $msg, $xmlout);
            }
        }
    }

    # Last resort, try each of the operations for the first which
    # can be parsed correctly.
    if($self->{accept_slow_select})
    {   keys %$handlers;  # reset each()
        $info->{selected_by} = 'attempt all';
        while(my ($name, $handler) = each %$handlers)
        {   my ($rc, $msg, $xmlout) = $handler->($name, $xmlin, $info);
            defined $xmlout or next;

            trace "data ready for $version $name";
            return ($rc, $msg, $xmlout);
        }
    }

    my $bodyel = $info->{body}[0] || '(none)';
    my @other  = sort grep {$_ ne $version && keys %{$self->{$_}}}
        $self->soapVersions;

    return (RC_SEE_OTHER, 'SOAP protocol not in use'
             , $server->faultTryOtherProtocol($bodyel, \@other))
        if @other;

    my @available = sort keys %$handlers;
    ( RC_NOT_FOUND, 'message not recognized'
    , $server->faultMessageNotRecognized($bodyel, $soapaction, \@available));
}

=section Preparations

=method operationsFromWSDL WSDL, OPTIONS
Compile the operations found in the WSDL object (an
M<XML::Compile::WSDL11>).  You can add the operations from many different
WSDLs into one server, simply by calling this method repeatedly.

=option  callbacks HASH
=default callbacks {}
The keys are the port names, as defined in the WSDL.  The values are CODE
references which are called in case a message is received which is
addressing the port (this is a guess). See L</Operation handlers>

=option  default_callback CODE
=default default_callback <produces fault reply>
When a message arrives which has no explicit handler attached to it,
this handler will be called.  By default, an "not implemented" fault will
be returned.  See L</Operation handlers>
=cut

sub operationsFromWSDL($@)
{   my ($self, $wsdl, %args) = @_;
    my %callbacks  = $args{callbacks} ? %{$args{callbacks}} : ();
    my %names;

    my $default_cb = $args{default_callback};
    my $wsa_input  = $self->{wsa_input};
    my $wsa_output = $self->{wsa_output};

    my @ops  = $wsdl->operations;
    unless(@ops)
    {   info __x"no operations in WSDL";
        return;
    }

    foreach my $op (@ops)
    {   my $name = $op->name;
        $names{$name}++;
        my $code;

        if(my $callback = delete $callbacks{$name})
        {   UNIVERSAL::isa($callback, 'CODE')
               or error __x"callback {name} must provide a CODE ref"
                    , name => $name;

            trace __x"add handler for operation `{name}'", name => $name;
            $code = $op->compileHandler(callback => $callback);
        }
        else
        {   trace __x"add stub handler for operation `{name}'", name => $name;
            my $server  = $op->serverClass;
            my $handler = $default_cb
              || sub { $server->faultNotImplemented($name) };

            $code = $op->compileHandler(callback => $handler);
        }

        $self->addHandler($name, $op, $code);

        if($op->can('wsaAction'))
        {   $wsa_input->{$name}  ||= $op->wsaAction('INPUT');
            $wsa_output->{$name} ||= $op->wsaAction('OUTPUT');
        }
        $self->addSoapAction($name, $op->soapAction);
    }

    info __x"added {nr} operations from WSDL", nr => (scalar @ops);

    warning __x"no operation for callback handler `{name}'", name => $_
        for sort keys %callbacks;

    $self;
}

=method addHandler NAME, SOAP, CODE
The SOAP value is C<SOAP11>, C<SOAP12>, or a SOAP server object or and
SOAP Operation object.  The CODE reference is called with the incoming
document (an XML::LibXML::Document) of the received input message.

In case the handler does not understand the message, it should
return undef.  Otherwise, it must return a correct answer message as
XML::LibXML::Document.
=cut

sub addHandler($$$)
{   my ($self, $name, $soap, $code) = @_;

    my $version = ref $soap ? $soap->version : $soap;
    $self->{handler}{$version}{$name} = $code;
}

=section Helpers

=method handlers ('SOAP11'|'SOAP12'|SOAP)
Returns all the handler names for a certain soap version.
=example
 foreach my $version (sort $server->soapVersions)
 {   foreach my $action (sort $server->handlers($version))
     {  print "$version $action\n";
     }
 }
=cut

sub handlers($)
{   my ($self, $soap) = @_;
    my $version = ref $soap ? $soap->version : $soap;
    my $table   = $self->{handler}{$version} || {};
    keys %$table;
}

=method soapVersions
=cut

sub soapVersions() { sort keys %{shift->{handler}} }

=method printIndex [FILEHANDLE]
Print a table which shows the messages that the server can handle,
by default to STDOUT.
=cut

sub printIndex(;$)
{   my $self = shift;
    my $fh   = shift || \*STDOUT;

    foreach my $version ($self->soapVersions)
    {   my @handlers = $self->handlers($version);
        @handlers or next;

        local $" = "\n   ";
        $fh->print("$version:\n   @handlers\n");
    }
}

=method faultInvalidXML ERROR
=cut

sub faultInvalidXML($)
{   my ($self, $error) = @_;
    ( RC_UNPROCESSABLE_ENTITY, 'XML syntax error'
    , __x("The XML cannot be parsed: {error}", error => $error));
}

=method faultNotSoapMessage NODETYPE
=cut

sub faultNotSoapMessage($)
{   my ($self, $type) = @_;
    ( RC_FORBIDDEN, 'message not SOAP'
    , __x( "The message was XML, but not SOAP; not an Envelope but `{type}'"
         , type => $type));
}

=method faultUnsupportedSoapVersion ENV_NS
Produces a text message, because we do not know how to produce
an error in a SOAP which we do not understand.
=cut

sub faultUnsupportedSoapVersion($)
{   my ($self, $envns) = @_;
    ( RC_NOT_IMPLEMENTED, 'SOAP version not supported'
    , __x("The soap version `{envns}' is not supported", envns => $envns));
}

=chapter DETAILS

=section Configuration options

This module will wrap any kind of M<Net::Server>, for instance a
M<Net::Server::PreFork>.  It depends on the type of C<Net::Server>
you specify (see M<new(based_on)>) which conifguration options are
available on the command-line, in a configuration file, or with M<run()>.
Each daemon extension implementation will add some configuration options
as well.

Any C<XML::Compile::SOAP::Daemon> object will have the following additional
configuration options:

  Key          Value                            Default
  # there will be some, I am sure of it.

Some general configuration options of Net::Server have a different default.
See also the next section about logging.

  Key          Value                            New default
  setsid       boolean                          true
  background   boolean                          true

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

=subsection Operation handlers

Per operation, you define a callback which handles the request. There can
also be a default callback for all your operations. Besides, when an
operation does not have a handler defined, one is created for you.

 sub my_callback($$)
 {   my ($soap, $data_in) = @_;

     return $data_out;
 }

The C<$data_out> is a nested HASH which will be translated in the right
XML structure.  This could be a Fault, like shown in the next section.

Please take a look at the scripts in the example directory within
the distribution.

=subsection Returning general errors

To have a handler return an error, leave the callback with something
like this:

 use XML::Compile::Util        qw/pack_type/;

 sub my_callback($$)
 {   my ($soap, $data) = @_;

     my $code = pack_type $my_err_ns, 'error-code';

     return
      +{ Fault =>
          { faultcode   => $code
          , faultstring => 'something is wrong'
          , faultactor  => $soap->role
          }
       , _RETURN_CODE => 404
       , _RETURN_TEXT => 'sorry, not found'
       };
 }

Fault codes are "prefix:error-name", XML::Compile finds the right prefix
based on the URI. If your error namespace is not mentioned in the WSDL or
other loaded schemas, you should use M<XML::Compile::WSDL11::prefixes()>
first.

SOAP uses error codes in the SOAPENV namespace.  It shows whether errors
are client or server side. This is produced like:

  use XML::Compile::SOAP::Util 'SOAP11ENV';
  $code = pack_type SOAP11ENV, 'Server.validationFailed';

[release 2.02] Fields C<_RETURN_CODE> and C<_RETURN_TEXT> can be used to
change the HTTP response (and maybe other protocol headers in the future).
These can also be used with valid answers, not limited to errors. There
is no clear definition how SOAP faults and HTTP return codes should work
together for user errors.

=subsection Returning private errors

In a WSDL, we can specify own fault types. These defined elements descripe
the C<detail> component of the message.

To return such an error, you have to figure-out how the fault part is
named. Often, the name simply is C<fault>.  Then, your handle has to
return a Fault structure where the detail refers to a HASH with data
matching the need for the fault.  Example:

  return
  +{ fault =>   # the name of the fault part, often "fault"
       { faultcode   => pack_type(SOAP11ENV, 'Server')
       , faultstring => 'any-ns.WentWrong'
       , faultactor  => $soap->role
       , detail      => { message => 'Hello, World!' }
       }
   };

=cut

1;

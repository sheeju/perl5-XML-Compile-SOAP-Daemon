# This code is part of distribution XML-Compile-SOAP-Daemon.  Meta-POD
# processed with OODoc into POD and HTML manual-pages.  See README.md
# Copyright Mark Overmeer.  Licensed under the same terms as Perl itself.

package XML::Compile::SOAP::Daemon;

use warnings;
use strict;

use Log::Report 'xml-compile-soap-daemon';

use XML::LibXML        ();
use XML::Compile::Util qw/type_of_node/;
use XML::Compile::SOAP ();

# We use HTTP status definitions for each soap protocol, but HTTP::Status
# may not be installed.
use constant
  { RC_SEE_OTHER            => 303
  , RC_FORBIDDEN            => 403
  , RC_NOT_FOUND            => 404
  , RC_UNPROCESSABLE_ENTITY => 422
  , RC_NOT_IMPLEMENTED      => 501
  };

my $parser        = XML::LibXML->new;

=chapter NAME

XML::Compile::SOAP::Daemon - SOAP accepting server (base class)

=chapter SYNOPSIS
 #### have a look in the examples directory!
 use XML::Compile::SOAP::Daemon::CGI;
 my $daemon  = XML::Compile::SOAP::Daemon::CGI->new;

 # operation definitions from WSDL
 my $wsdl    = XML::Compile::WSDL11->new(...);
 $wsdl->importDefinitions(...); # more schemas
 $daemon->operationsFromWSDL($wsdl, callbacks => ...);

 $daemon->setWsdlResponse($wsdl_fn);
 $daemon->setWsdlResponse($wsdl_fn, $soap11->mediaType);

 # operation definitions added manually
 my $soap11  = XML::Compile::SOAP11::Server->new(schemas => $wsdl->schemas);
 my $handler = $soap11->compileHandler(...);
 $daemon->addHandler('getInfo', $soap11, $handler);

=chapter DESCRIPTION

This base class implements the common needs between various types of
SOAP daemons. Ache daemon can handle various kinds of SOAP protocols at
the same time, when possible hidden from the user of this module.

The following extensions are implemented on the moment:

=over 4

=item *

M<XML::Compile::SOAP::Daemon::AnyDaemon>, for transport over HTTP
based on M<Any::Daemon> (a generic pre-forked daemon) and M<LWP>.
It uses M<Log::Report> as exception and loggin frame-work, just as all
C<XML::Compile> modules do, hence cleaner integration.

=item *

M<XML::Compile::SOAP::Daemon::CGI>, for transport over HTTP
based on M<CGI> and M<LWP>.

=item *

M<XML::Compile::SOAP::Daemon::PSGI> allows to run SOAP server as a
part of larger PSGI application (mixing webservice with standard
webserver) or to integrate with existing event loop framework (AnyEvent,
Coro, POE).

=item *

M<XML::Compile::SOAP::Daemon::NetServer>, for transport over HTTP
based on M<Net::Server> and M<LWP>.  The C<Net::Server> distribution
offers a number of very different daemon implementations.  There are
too many ways to configure it.

=back

If you have a WSDL describing your procedures (operations), then the
only thing you have to worry about is adding callbacks for each of the
defined ports.  Without WSDL, you will need to do more manually, but it
is still relatively simple to achieve.

Do not forget to take a look at the extensive example, enclosed in the
M<XML::Compile::SOAP::Daemon> distribution package.  It is really worth
the time.

=chapter METHODS

=section Constructors

=c_method new %options

=option  output_charset STRING
=default output_charset 'UTF-8'
The character-set to be used for the output XML document.

=option  wsa_action_input HASH|ARRAY
=default wsa_action_input {}
The keys are port names, the values are strings which are used by
clients to indicate which server operation they want to use. Often,
an WSDL contains this information in C<wsaw:Action> attributes; that
info is added to this HASH automatically when M<XML::Compile::SOAP::WSA>
is loaded.

=option  wsa_action_output HASH|ARRAY
=default wsa_action_output {}
The keys are port names, the values are strings which the server will
add to replies to the client. Often, an WSDL contains this information in
C<wsaw:Action> attributes; that info is added to this HASH automatically
when M<XML::Compile::SOAP::WSA> is loaded.

=option  soap_action_input HASH|ARRAY
=default soap_action_input {}
The keys are port names, with as value the related SOAPAction header
field content (without quotes). Often, these SOAPAction fields originate
from the WSDL.

=option  accept_slow_select BOOLEAN
=default accept_slow_select <true>
Traditional SOAP does not have a simple way to find out which operation
is being called. The only way to determine which operation is needed,
is by trying all defined operations until one matches.

Later, people started to use the soapAction HTTP header (which
was officially only for proxies) and then the WSA SOAP header
extension. Either of them make it easy to determine the right handler
one on one.

Disabling C<accept_slow_select> will protect you against various
forms of DoS-attacks, however this is often not possible as many
WSDLs do not define soapAction or WSA action keys.
=cut

sub new(@)
{   my $class = shift;
    $class ne __PACKAGE__
        or error __x"you can only use extensions of {pkg}", pkg => __PACKAGE__;
    (bless {}, $class)->init( {@_} );
}

sub init($)
{   my ($self, $args) = @_;
    $self->{accept_slow_select}
      = exists $args->{accept_slow_select} ? $args->{accept_slow_select} : 1; 

    $self->addWsaTable(INPUT  => $args->{wsa_action_input});
    $self->addWsaTable(OUTPUT => $args->{wsa_action_output});
    $self->addSoapAction($args->{soap_action_input});

    if(my $support = delete $args->{support_soap})
    {   # simply only load the protocol versions you want to accept.
        error __x"new(support_soap} removed in 2.00";
    }

    my @classes = XML::Compile::SOAP->registered;
    @classes   # explicit load required since 2.00
        or warning "No protocol modules loaded.  Need XML::Compile::SOAP11?";

    $self->{output_charset} = delete $args->{output_charset} || 'UTF-8';
    $self->{handler}        = {};
    $self;
}

#-----------
=section Attributes

=method outputCharset
The character-set to be used for output documents.
=cut

sub outputCharset() {shift->{output_charset}}

=method addWsaTable <'INPUT'|'OUTPUT'>, [HASH|PAIRS]
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

#------------------
=section Running the server

=method run %options
How the daemon is run depends much on the extension being used. See the
C<::NetServer> and C<::CGI> manual-page.
=cut

sub run(@)
{   my ($self, %args) = @_;
    notice __x"WSA module loaded, but not used"
        if XML::Compile::SOAP::WSA->can('new') && !keys %{$self->{wsa_input}};

    $self->{wsa_input_rev}  = +{ reverse %{$self->{wsa_input}} };
    $self->_run(\%args);
}

=method process $client, $xmlin, $request, $action
This method is called to process a single request.
The $xmlin is a SOAP-structured message (an M<XML::LibXML::Element>,
M<XML::LibXML::Document>, or XML as string), was received from the $client
(some extension specific object).

The full $request is passed in, however its format depends on the
kind of server. The $action parameter relates to the soapAction header
field which may be available in some form.

Returned is an XML document (M<XML::LibXML::Document>) as answer or a
protocol specific ready response object (usually an error object).

This C<process> method will determine which callback routine to use to
generate a reply and then call the routine. See L</Operation handlers>
for details on how the routines are called.

See M<operationsFromWSDL()> and M<addHandler()> on how the callback
routines can be specified.  See M<new()> for a description of the options
which control how the callback routine is chosen.

=cut

# defined by Net::Server
sub process_request(@) { panic "must be extended" }

sub process($)
{   my ($self, $input, $req, $soapaction) = @_;

    my $xmlin;
    if(! defined $input)
    {  return $self->faultNotSoapMessage('No input');
    }
    elsif(ref $input eq 'SCALAR')
    {   $xmlin = try { $parser->parse_string($$input) };
        return $self->faultInvalidXML($@->wasFatal) if $@;
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
    my $proto  = XML::Compile::SOAP->fromEnvelope($envns)
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
            my ($rc, $msg, $xmlout) = $handler->($name, $xmlin, $info, $req);
            if($xmlout)
            {   trace "data ready for $version $name, via wsa $wsa_action";
                return ($rc, $msg, $xmlout);
            }
        }
    }

    # Try to resolve operation via soapAction
    my $sa = $self->{sa_input_rev};
    if(defined $soapaction)
    {   if(my $name = $sa->{$soapaction})
        {   my $handler = $handlers->{$name};
            local $info->{selected_by} = 'soap-action';
            my ($rc, $msg, $xmlout) = $handler->($name, $xmlin, $info, $req);
            if($xmlout)
            {   trace "data ready for $version $name, via sa '$soapaction'";
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
        {   my ($rc, $msg, $xmlout) = $handler->($name, $xmlin, $info, $req);
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

    # we do not have the names of the request body elements here :(
    my @ports = sort keys %$handlers;

      ( RC_NOT_FOUND, 'message not recognized'
      , $server->faultMessageNotRecognized($bodyel, $soapaction, \@ports)
      );
}

#------------------
=section Preparations

=method operationsFromWSDL $wsdl, %options
Compile the operations found in the $wsdl object (an
M<XML::Compile::WSDL11>).  You can add the operations from many different
WSDLs into one server, simply by calling this method repeatedly.

You can also specify %options for M<XML::Compile::WSDL11::operations()>.
Those parameters may be needed to distinguish between the test-server
and the live-server, provided protocol support and such.

=option  callbacks HASH
=default callbacks {}
The keys are the port names, as defined in the $wsdl.  The values are CODE
references which are called in case a message is received which is
addressing the port (this is a guess). See L</Operation handlers>

=option  default_callback CODE
=default default_callback <produces fault reply>
When a message arrives which has no explicit handler attached to it,
this handler will be called.  By default, an "not implemented" fault will
be returned.  See L</Operation handlers>

=option  operations ARRAY
=default operations undef
Load the selected operations only (M<XML::Compile::SOAP::Operation> objects)
If not specified, all operations will be taken which are selected with
the C<service>, C<port>, and C<binding> %options for
M<XML::Compile::WSDL11::operations()>.

=example
 $daemon->operationsFromWSDL($wsdl, service => 'MyService',
    binding => 'MyService-soap11', callbacks => {get => \$f11});
 $daemonwsdl->operationsFromWSDL($wsdl, service => 'MyService-test',
    binding => 'MyService-soap12', callbacks => {get => \$f12});
=cut

sub operationsFromWSDL($@)
{   my ($self, $wsdl, %args) = @_;
    my %callbacks  = $args{callbacks} ? %{$args{callbacks}} : ();
    my %names;

    my $default_cb = $args{default_callback};
    my $wsa_input  = $self->{wsa_input};
    my $wsa_output = $self->{wsa_output};

    my $ops = $args{operations};
    my @ops = $ops ? @$ops : $wsdl->operations(%args);
    @ops or return;   # none selected

    foreach my $op (@ops)
    {   my $name = $op->name;
        warning __x"multiple operations with name `{name}'", name => $name
            if $names{$name}++;

        my $code;
        if(my $callback = $callbacks{$name})
        {   UNIVERSAL::isa($callback, 'CODE')
               or error __x"callback {name} must provide a CODE ref"
                    , name => $name;

            trace __x"add handler for operation `{name}'", name => $name;
            $code = $op->compileHandler(callback => $callback);
        }
        else
        {   trace __x"add stub handler for operation `{name}'", name => $name;
            my $handler = $default_cb
              || sub { $_[0]->faultNotImplemented($name) };

            $code = $op->compileHandler(callback => $handler);
        }

        $self->addHandler($name, $op, $code);

        if($op->can('wsaAction'))
        {   my $in  = $op->wsaAction('INPUT');
            $wsa_input->{$name}  = $in if defined $in;
            my $out = $op->wsaAction('OUTPUT');
            $wsa_output->{$name} = $out if defined $out;
        }
        $self->addSoapAction($name, $op->soapAction);
    }

    info __x"added {nr} operations from WSDL", nr => (scalar @ops);

    if(keys %names != keys %callbacks)
    {   $names{$_}
            or warning __x"no operation for callback handler `{name}'",name=>$_
                for sort keys %callbacks;
    }

    $self;
}

=method addHandler $name, $soap, CODE
The $soap value is C<SOAP11>, C<SOAP12>, or a $soap server object or and
$soap Operation object.  The CODE reference is called with the incoming
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

=method setWsdlResponse $filename, [$filetype]
Many existing SOAP servers will response to GET queries which end on "?WSDL"
by sending the WSDL in use by the service.

The default $filetype is C<application/wsdl+xml>.  You may need C<text/xml>
=cut

sub setWsdlResponse($;$)
{   my ($self, $filename, $type) = @_;
    panic "not implemented by backend {pkg}", pkg => (ref $self || $self);
}

#------------------
=section Helpers

=method handlers <'SOAP11'|'SOAP12'|$soap>
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

=method printIndex [$fh]
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

=method faultInvalidXML $error
=cut

sub faultInvalidXML($)
{   my ($self, $error) = @_;
    ( RC_UNPROCESSABLE_ENTITY, 'XML syntax error'
    , __x("The XML cannot be parsed: {error}", error => $error));
}

=method faultNotSoapMessage $nodetype
=cut

sub faultNotSoapMessage($)
{   my ($self, $type) = @_;
    ( RC_FORBIDDEN, 'message not SOAP'
    , __x( "The message was XML, but not SOAP; not an Envelope but `{type}'"
         , type => $type));
}

=method faultUnsupportedSoapVersion $env_ns
Produces a text message, because we do not know how to produce
an error in a SOAP which we do not understand.
=cut

sub faultUnsupportedSoapVersion($)
{   my ($self, $envns) = @_;
    ( RC_NOT_IMPLEMENTED, 'SOAP version not supported'
    , __x("The soap version `{envns}' is not supported", envns => $envns));
}

#------------------
=chapter DETAILS

=section Operation handlers

Per operation, you define a callback which handles the request. There can
also be a default callback for all your operations. Besides, when an
operation does not have a handler defined, one is created for you.

 sub my_callback($$$)
 {   my ($soap, $data_in, $request) = @_;

     return $data_out;
 }

The C<$soap> parameter is the actual C<XML::Compile::SOAP> object which
handles this protocol version (at the moment only M<XML::Compile::SOAP11>.
C<$data_in> is a HASH with the decoded information from the request.
The type and content of C<$request> depends on the type of server,
often an M<HTTP::Request>.

The C<$data_out> is a nested HASH which will be translated in the right
XML structure.  This could be a Fault, like shown in the next section.

Please take a look at the scripts in the F<examples/> directory within
the distribution.

=section Returning errors

In WSDLs you may find explicitly defined error details types. There is
only one such error structure per operation: when an operation may return
different kinds of errors, they will be wrapped into one structure which
contains the details. See section L</"Returning private errors"> below.

Errors which do not return an C<details> record can always be reported
with code and string. Let's first explain those.

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

B<Be warned> that WCF (MicroSoft's .NET) interprets the return code in
SOAP1.2 style, not SOAP1.1.  The 1.2 specification says that only
_RETURN_CODE 200 and 202 can contain a SOAP respons.  Other servers will
code the content for any 2xx code.

=subsection Returning private errors

In a WSDL, we can specify own fault types. These defined elements describe
the C<detail> component of the message.

For example, in the WSDL and Schema we may have:

 <xs:element name="errorReportMsg" type="ErrorReportType"/>
 <xs:complexType name="ErrorReportType">
   <xs:sequence>
     <xs:element name="info" type="string">
     <xs:element name="cause" type="string" minOccurs="0">
   </xs:sequence>
 </xs:complexType>

 <message name="ErrorReport">
     <part name="message" element="tmdd:errorReportMsg"/>
 </message>

 <operation name="GetData">
   <input message="GetDataRequest"/>
   <output message="GetDataRequest"/>
   <fault name="errorReport" message="ErrorReport"/>
 </operation>

To return a private error you need to determine the name of the fault
part.  In the example above the fault parts name is C<errorReport>.
However,  in some WSDLs the C<name> option is not present and
M<XML::Compile::SOAP> assumes that C<fault> will be used to indicate
the fault part.

You need to return a HASH with values for the ErrorReport element
together with values for the fields in the Fault value shown
in the previous section.  For example:

  my $msg = "Unknown Error";
  return
   +{ errorReport =>   # the name of the fault part
        { # this gets put into the 'detail' part of
          # the fault message
          info => $msg

          # these are used for the other parts of the fault message
        , faultcode   => pack_type(SOAP11ENV, 'Server.BadOperation')
        , faultstring => $msg
        , faultactor  => $soap->role
        }
    };

If no name is specified for the fault part, then you can use:

  return
   +{ fault =>   # the name of the fault part
        { faultcode   => pack_type(SOAP11ENV, 'Server.BadOperation')
        , faultstring => $msg
        , faultactor  => $soap->role
        , detail => { info=> $msg }
        }
    };

It has been observed that several SOAP toolkits do not handle user defined
faults messages very well.  However, they do provide the faultcode and
faultstring values from the fault message.

=cut

1;

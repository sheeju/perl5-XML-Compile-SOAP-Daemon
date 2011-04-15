use warnings;
use strict;

package XML::Compile::SOAP::Daemon::CGI;
use base 'XML::Compile::SOAP::Daemon';

our @ISA;

use Log::Report 'xml-compile-soap-daemon';
use CGI 3.50, ':cgi';

=chapter NAME
XML::Compile::SOAP::Daemon::CGI - CGI based server

=chapter SYNOPSIS
 #### have a look in the examples directory!
 use XML::Compile::SOAP::Daemon::CGI;
 my $daemon  = XML::Compile::SOAP::Daemon::CGI->new;

 # daemon definitions from WSDL
 my $wsdl    = XML::Compile::WSDL11->new(...);
 $wsdl->importDefinitions(...); # more schemas
 $daemon->operationsFromWSDL($wsdl, callbacks => ...);

=chapter DESCRIPTION
This module handles the exchange of SOAP messages via Apache, using
the popular Perl module M<CGI>.

This abstraction level of the object (code in this pm file) is not
concerned with parsing or composing XML, but only worries about the
HTTP transport specifics of SOAP messages.

=chapter METHODS

=section Constructors

=c_method new OPTIONS

=section Running the server

=method run OPTIONS
=cut

sub runCgiRequest(@) {shift->run(@_)}

# called by SUPER::run()
sub _run($)
{   my ($self, $args) = @_;

    my $q = CGI->new;

    my ($rc, $msg, $xmlout)
      = $self->process(\$query->param('POSTDATA'), $q, $ENV{soapAction});

    print $q->( -type  => 'text/xml'
              , -nph    => 1
              , -status => "$rc $msg"
              , -Content_length => length($xmlout)
              );

    print $xmlout;
}

#-----------------------------

=chapter DETAILS

=section How to use this CGI module

The code and documentation for this module was contributed by Patrick
Powell in December 2010. Both have seen major changes since.

=subsection Configuring

Go to the F<examples/mod_perl/> directory which is included in
the distribution of this module, M<XML::Compile::SOAP::Daemon>.
There you find a README describing the process.

=cut

1;

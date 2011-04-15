
package XML::Compile::SOAP::HTTPDaemon;

use XML::Compile::SOAP::Daemon::NetServer;

# For more than one reason, this module has changed name. The most
# important being that HTTPDaemon seems to relate to HTTP::Daemon
# from LWP... which is not true!

BEGIN
{
    print STDERR <<'_ERR';

*
*** Since v3.00, XML::Compile::SOAP::HTTPDaemon renamed to
*** XML::Compile::SOAP::Daemon::NetServer.  Please change
*** your code (besides this message it should still work)
*

_ERR
    sleep 5
}

sub new(@)
{   my $class = shift;
    XML::Compile::SOAP::Daemon::NetServer->new(@_);
}

1;

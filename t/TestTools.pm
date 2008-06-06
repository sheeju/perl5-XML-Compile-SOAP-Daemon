use warnings;
use strict;

# test environment at home: unpublished XML::Compile
use lib '../XMLCompile/lib';
use lib '../XMLSOAP/lib';
use lib '../XMLTester/lib';
use lib '../LogReport/lib';

package TestTools;
use base 'Exporter';

our @EXPORT = qw/
 /;

our $TestNS   = 'http://test-types';

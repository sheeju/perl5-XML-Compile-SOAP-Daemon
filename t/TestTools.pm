use warnings;
use strict;

# test environment at home: unpublished XML::Compile
use lib '../XMLCompile/lib', '../../XMLCompile/lib';
use lib '../XMLSOAP/lib', '../../XMLSOAP/lib';
use lib '../LogReport/lib', '../../LogReport/lib';

package TestTools;
use base 'Exporter';

use XML::LibXML;
use Test::More;
use Test::Deep   qw/cmp_deeply/;

use POSIX        qw/_exit/;
use Log::Report  qw/try/;
use Data::Dumper qw/Dumper/;

our @EXPORT = qw/
 /;

our $TestNS   = 'http://test-types';

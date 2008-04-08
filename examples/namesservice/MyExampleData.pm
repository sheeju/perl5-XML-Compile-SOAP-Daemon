use warnings;
use strict;

package MyExampleData;
use base 'Exporter';

our @EXPORT = qw/$namedb/;

our $namedb =
 { Netherlands =>
    {   male  => [ qw/Mark Tycho Thomas/ ]
    , female  => [ qw/Cleo Marjolein Suzanne/ ]
    }
 , Austria     =>
    {   male => [ qw/Thomas Samuel Josh/ ]
    , female => [ qw/Barbara Susi/ ]
    }
 ,German       =>
    {   male => [ qw/Leon Maximilian Lukas Felix Jonas/ ]
    , female => [ qw/Leonie Lea Laura Alina Emily/ ]
    }
 };

1;

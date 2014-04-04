#!/perl

use strict;
use warnings;
use Test::More;
useok( Debug );

my $test = {
    array => [
        { paynum => 1 },
        { paynum => 2 }
    ],
    hi => 'bye',
    pkgnum => 42,
    hash => {
        what => 'how?',
        another_hash => {
            some_key => 'yeah',
            custnum  => 2
        },
        custnum => 1,
        rows => [
            { agent => 'voldemort' },
            { agent => 'smith' }
        ]
    }
};

debug($test);
sub what_is_this {

}

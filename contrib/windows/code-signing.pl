#!perl

use strict;
use warnings;

use constant bash => 'C:\Program Files\Git\bin\bash.exe';

die "missing git bash environment\n" unless -e bash;

# Script assuming a private.key file has been created in the current folder
die "missing private.key file\n" unless -e "private.key";

my ($source) = @ARGV;

$source =~ s/\\/\//g;

my $signed = $source =~ /^(.*)\.(\w+)$/ ? "$1-signed.$2" : $source . "-signed";

my @ssh = ("ssh", "-T", "-o", "StrictHostKeyChecking=yes", "-i", "private.key");
push @ssh, "codesign", "codesign", $source;

system(bash, "-c", "cat '$source' | @ssh >'$signed'") == 0
    or die "Failed to sign $source\n";

die "Failed to sign $source: empty result\n"
    unless -s $signed;

unlink $source
    or die "Failed to remove $source: $!\n";

rename $signed, $source
    or die "Failed to rename $signed into $source: $!\n";

exit(0);

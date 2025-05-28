#!perl

use strict;
use warnings;

use constant bash => 'C:\Program Files\Git\bin\bash.exe';

die "missing git bash environment\n" unless -e bash;

# Script assuming a private.key file has been created in the current folder
die "missing private.key file\n" unless -e "private.key";

my ($source, $signed) = @ARGV;

$source =~ s/\\/\//g;
$signed =~ s/\\/\//g;

my @ssh = ("ssh", "-T", "-o", "StrictHostKeyChecking=yes", "-i", "private.key");
push @ssh, "codesign", "codesign", $source;

system(bash, "-c", "cat '$source' | @ssh >'$signed'");

#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long;
use SEO::Checker;

my $mobile = 0;
my $keyword;
my $phase = 'all';   # can be 1_2, 3, 4 or all
my $url;

GetOptions(
    "mobile"   => \$mobile,
    "keyword=s" => \$keyword,
    "phase=s"  => \$phase,
) or die "Usage: $0 --mobile --keyword=foo --phase=all|1_2|3|4 <URL>\n";

$url = shift @ARGV or die "Usage: $0 --mobile --keyword=foo --phase=all|1_2|3|4 <URL>\n";

my $checker = SEO::Checker->new(
    url => $url,
    mobile => $mobile,
    keyword => $keyword,
);

$checker->fetch;

if ($phase eq '1_2' or $phase eq 'all') {
    print "\n=== Running Phase 1 & 2 Checks ===\n";
    $checker->phase_1_2_checks;
}
if ($phase eq '3' or $phase eq 'all') {
    print "\n=== Running Phase 3 Checks ===\n";
    $checker->phase_3_checks;
}
if ($phase eq '4' or $phase eq 'all') {
    print "\n=== Running Phase 4 Checks ===\n";
    $checker->phase_4_checks;
}

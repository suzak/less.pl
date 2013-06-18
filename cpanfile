my $fn = __FILE__;
$fn =~ s{[^/\\]+$}{};
$fn ||= '.';
$fn .= '/config/perl/modules.txt';
open my $f, $fn;
while (<$f>) {
    chomp;
    requires $_;
}

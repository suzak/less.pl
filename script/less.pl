#!/usr/bin/env perl
use strict;
use warnings;

use AnyEvent;
use AnyEvent::Util qw(run_cmd);
use File::Zglob;
use Filesys::Notify::Simple;
use Getopt::Long;
use List::MoreUtils qw(all);
use Path::Class qw(file);

my $root = file('dummy')->absolute->parent;

GetOptions(
    '--node=s' => \(my $node = `which node`),
    '--lessc=s' => \(my $lessc = "$root/node_modules/less/bin/lessc"),
    '--less-dir=s' => \my $lessdir,
    '--css-dir=s' => \my $cssdir,
    '--tmp-dir=s' => \my $tmpdir,
    '--include-dir=s' => \my @incdir,
    '--ignore=s' => \my @ignore,
);

chomp $node;
$_ = $root->subdir($_) for $lessdir, $cssdir, $tmpdir, @incdir;
$_ = qr<$_> for @ignore;

# { 'dependent file name' => { 'dependency file name' => 1, ... }, ... }
my $dependencies = { };

sub read_depsfile ($) {
    my ($depsfile) = @_;
    my $deps = $depsfile->slurp;
    for (map { [ split /\s*:\s*/, $_ ] } grep { $_ } split /\n/, $deps) {
        next if ! defined $_->[1];
        (my $target = $_->[0]) =~ s/^$cssdir/$lessdir/;
        $target =~ s/\.css$/.less/;
        $dependencies->{$target} = { map { $_ => 1 } split /\s+/, $_->[1] };
    }
}

sub counterparts ($) {
    my ($less) = @_;
    (my $depsfile = $less) =~ s!^$root/!!;
    $depsfile = $tmpdir->file("$depsfile.dep");
    (my $css = $less) =~ s!^$lessdir/!!;
    $css =~ s/\.less$/.css/;
    $css = $cssdir->file($css);
    return ($css, $depsfile);
}

sub compile ($);
sub compile ($) {
    my ($less) = @_;
    my ($css, $depsfile) = counterparts $less;
    $depsfile->parent->mkpath;
    if ($less =~ qr<^$lessdir/> && all { $less !~ $_ } @ignore) {
        my @depsfile_times;
        if (-e $depsfile) {
            @depsfile_times = (stat $depsfile)[8, 9]; # 8 = atime, 9 = mtime
        }
        $css->parent->mkpath unless -e $css;
        chmod 0644, $css if -e $css; # octal
        my $cv1 = AnyEvent->condvar;
        my $cv2 = run_cmd [$node, $lessc, (map "-I$_", @incdir), $less, $css];
        $cv2->cb(sub {
            if (!$_[0]->recv) {
                print "$less: compiled\n";
                chmod 0444, $css; # octal
                run_cmd([$node, $lessc, '-depends', (map "-I$_", @incdir), $less, $css],
                        '>' => $depsfile->open('w'))->cb(sub {
                    read_depsfile $depsfile;
                    $cv1->send;
                });
            } else {
                if (-e $depsfile) {
                    if (@depsfile_times) {
                        utime @depsfile_times, $depsfile;
                    } else {
                        $depsfile->remove;
                    }
                }
                $cv1->send;
            }
        });
        $cv1->recv;
    } else {
        $depsfile->open('w'); # touch
    }
    compile $_ for grep { $dependencies->{$_}->{$less} } keys %$dependencies;
}

for my $deps (zglob("$tmpdir/**/*.dep")) {
    read_depsfile file($deps);
}

for my $less (zglob("$lessdir/**/*.less")) {
    my (undef, $depsfile) = counterparts $less;
    if (!-e $depsfile || (stat $depsfile)[9] < (stat $less)[9]) { # 9 = mtime
        compile $less;
    }
}

my $watcher = Filesys::Notify::Simple->new([$lessdir, @incdir]);
while (1) {
    $watcher->wait(sub {
        compile $_ for grep { m</(?!\.)[\w\-.]+\.less$> } map { $_->{path} } @_;
    });
}

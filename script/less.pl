#!/usr/bin/env perl
use v5.14;
use strict;
use warnings;

use File::Zglob;
use Filesys::Notify::Simple;
use Path::Class qw(file);

my $root = file(__FILE__)->parent->subdir(qw(.. ..))->absolute->resolve;
my $lessc = $root->file(qw(modules less.js bin lessc));
my $lessdir = $root->subdir(qw(static less));
my $cssdir = $root->subdir(qw(static css));
my $tmpdir = $root->subdir(qw(tmp less));

# { 'dependent file name' => { 'dependency file name' => 1, ... }, ... }
my $dependencies = { };

sub read_depsfile ($) {
    my ($depsfile) = @_;
    my $deps = $depsfile->slurp;
    for (map { [ split /\s*:\s*/, $_ ] } grep { $_ } split /\n/, $deps) {
        $dependencies->{$_->[0]} = { map { $_ => 1 } split /\s+/, $_->[1] };
    }
}

sub counterparts ($) {
    my ($less) = @_;
    (my $output = $less) =~ s"^$lessdir/"";
    my $depsfile = $tmpdir->file("$output.dep");
    $output =~ s/\.less$//;
    my $css = $cssdir->file("$output.css");
    return ($css, $depsfile);
}

sub compile ($);
sub compile ($) {
    my ($less) = @_;
    my ($css, $depsfile) = counterparts $less;
    if ($less !~ qr<^$lessdir/lib/>) { # mixin
        my @depsfile_times;
        if (-e $depsfile) {
            @depsfile_times = (stat $depsfile)[8, 9]; # 8 = atime, 9 = mtime
        } else {
            $depsfile->parent->mkpath;
        }
        chmod 0644, $css if -e $css; # octal
        my $ret = system('node',
                         $lessc,
                         "-I$lessdir/lib",
                         "-MF=$depsfile",
                         $less,
                         $css);
        if ($ret == 0) {
            say "$less: compiled";
            chmod 0444, $css; # octal
            read_depsfile $depsfile;
        } elsif (-e $depsfile) {
            if (@depsfile_times) {
                utime @depsfile_times, $depsfile;
            } else {
                $depsfile->remove;
            }
        }
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

my $watcher = Filesys::Notify::Simple->new([$lessdir]);
while (1) {
    $watcher->wait(sub {
        compile $_ for grep { /\.less$/ } map { $_->{path} } @_;
    });
}

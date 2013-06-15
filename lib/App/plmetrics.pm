package App::plmetrics;
use strict;
use warnings;
use Module::Path;
use Perl::Metrics::Lite;
use Statistics::Swoop;
use Text::ASCIITable;

our $VERSION = '0.05';

sub new {
    my ($class, $opt) = @_;
    bless +{ opt => $opt } => $class;
}

sub opt { $_[0]->{opt} }

sub run {
    my $self = shift;

    my ($targets, $base_path) = $self->_get_targets;
    my $metrics = $self->_get_metrics($targets, $base_path);
    $self->_stats($metrics);
}

sub _stats {
    my ($self, $metrics) = @_;

    my $result_opt = $self->opt->{'--result'};

    if (!$result_opt || $result_opt =~ m!^module$!i) {
        $self->_stats_module($metrics);
    }
    elsif ($result_opt =~ m!^methods?$!i) {
        $self->_stats_methods($metrics);
    }
    elsif ($result_opt =~ m!^cc$!i) {
        $self->_stats_cc($metrics);
    }
    elsif ($result_opt =~ m!^lines?$!i) {
        $self->_stats_lines($metrics);
    }
    else {
        print STDERR "wrong option: --result $result_opt\nsee the --help\n";
    }
}

sub _stats_cc {
    my ($self, $metrics) = @_;

    $self->_cc_lines($metrics, 'cc');
}

sub _stats_lines {
    my ($self, $metrics) = @_;

    $self->_cc_lines($metrics, 'lines');
}

sub _cc_lines {
    my ($self, $metrics, $label) = @_;

    print "$label\n";
    my $t = Text::ASCIITable->new;
    my @metrics_keys = keys %{$metrics};
    for my $pl ( $self->opt->{'--sort'} ? sort @metrics_keys : @metrics_keys ) {
        $t->setCols($self->_header);
        $t->addRow( $pl, $self->_row($metrics->{$pl}{$label}) );
    }
    print $t. "\n";
}

sub _header {
    return('', 'avg', 'max', 'min', 'range', 'sum', 'methods');
}

sub _row {
    my ($self, $list) = @_;

    my $stats = Statistics::Swoop->new($list);
    return( $self->_round($stats->avg), $stats->max, $stats->min,
                $stats->range, $stats->sum, $stats->count );
}

sub _stats_module {
    my ($self, $metrics) = @_;

    my @metrics_keys = keys %{$metrics};
    for my $pl ( $self->opt->{'--sort'} ? sort @metrics_keys : @metrics_keys ) {
        print "$pl\n";
        my $t = Text::ASCIITable->new;
        $t->setCols($self->_header);
        $t->addRow( 'cc', $self->_row($metrics->{$pl}{cc}) );
        $t->addRow( 'lines', $self->_row($metrics->{$pl}{lines}) );
        print $t. "\n";
    }
}

sub _round {
    sprintf("%.2f", $_[1]);
}

sub _stats_methods {
    my ($self, $metrics) = @_;

    my @metrics_keys = keys %{$metrics};
    for my $pl ( $self->opt->{'--sort'} ? sort @metrics_keys : @metrics_keys ) {
        my $t = Text::ASCIITable->new;
        $t->setCols('', 'cc', 'lines');
        my $ref = $metrics->{$pl}{method};
        my @methods_keys = keys %{$ref};
        for my $method ( $self->opt->{'--sort'} ? sort @methods_keys : @methods_keys ) {
            $t->addRow($method, $ref->{$method}{cc}, $ref->{$method}{lines});
        }
        print $t. "\n";
    }
}

sub _get_metrics {
    my ($self, $targets, $base_path) = @_;

    my $m = Perl::Metrics::Lite->new;
    my $analysis = $m->analyze_files(@{$targets});

    my %subs;
    for my $full_path (keys %{($analysis->sub_stats)}) {
        for my $sub (@{$analysis->sub_stats->{$full_path}}) {
            $sub->{path} =~ s!$base_path/!! if $base_path;
            my $cc    = $sub->{mccabe_complexity};
            my $lines = $sub->{lines};
            $subs{$sub->{path}}->{method}{$sub->{name}} = +{
                cc    => $cc,
                lines => $lines,
            };
            push @{ $subs{$sub->{path}}->{cc} }, $cc;
            push @{ $subs{$sub->{path}}->{lines} }, $lines;
        }
    }

    return \%subs;
}

sub _get_targets {
    my $self = shift;

    return   $self->opt->{'--dir'}    ? $self->_target_dir
           : $self->opt->{'--tar'}    ? $self->_target_tar
           : $self->opt->{'--git'}    ? $self->_target_git
           : $self->opt->{'--file'}   ? $self->_target_file
           : $self->opt->{'--module'} ? $self->_target_module : [];
}

sub _target_module {
    my $self = shift;

    my $path = Module::Path::module_path($self->opt->{'--module'});
    my @targets;
    if ($path) {
        push @targets, $path;
    }
    else {
        print STDERR "No such module: ". $self->opt->{'--module'}. "\n";
    }
    return(\@targets, '');
}

sub _target_file {
    my $self = shift;

    my @targets;
    push @targets, $self->opt->{'--file'} if -f $self->opt->{'--file'};

    return(\@targets, '');
}

sub _target_dir {
    my $self = shift;

    my @targets;
    my $dir = $self->opt->{'--dir'};
    push @targets, $dir if -d $dir;

    return(\@targets, $dir);
}

sub _target_git {
    my $self = shift;

    $self->_load_or_recommend(qw/
        File::Temp
        Path::Class
        Git::Repository
    /);

    my $work_dir = File::Temp::tempdir(CLEANUP => 1);
    my $repo_dir = Path::Class::dir($work_dir);

    Git::Repository->run(
        clone => $self->opt->{'--git'},
        $repo_dir->stringify,
    );

    my @targets;
    for my $dir (qw/lib script bin/) {
        my $dir_path = "$repo_dir/$dir";
        push @targets, $dir_path if -d $dir_path;
    }

    return(\@targets, $repo_dir);
}

sub _target_tar {
    my $self = shift;

    $self->_load_or_recommend(qw/
        File::Temp
        LWP::Simple
        Archive::Tar
    /);

    my $work_dir = File::Temp::tempdir(CLEANUP => 1);
    my ($fh, $filename) = File::Temp::tempfile(
        DIR    => $work_dir,
        SUFFIX => '.tar.gz',
    );

    my $tar_url = $self->opt->{'--tar'};
    my ($module_dir) = ($tar_url =~ m!/([^/]+)\.tar\.gz!);

    LWP::Simple::getstore($tar_url => $filename);

    my $tar = Archive::Tar->new;
    $tar->read($filename);
    $tar->setcwd($work_dir);
    $tar->extract;

    my @targets;
    for my $dir (qw/lib script bin/) {
        my $dir_path = "$work_dir/$module_dir/$dir";
        push @targets, $dir_path if -d $dir_path;
    }

    return(\@targets, "$work_dir/$module_dir");
}

sub _load_or_recommend {
    my ($self, @modules) = @_;

    for my $module (@modules) {
        eval {
            my $file = $module;
            $file =~ s!::!/!g;
            require "$file.pm"; ## no critic
        };
        if (my $e = $@) {
            die <<"_MESSAGE_";
ERROR: This system does NOT have [$module] for executing this task.
Would you mind installing $module?

\$ cpanm $module

_MESSAGE_
        }
        else {
            $module->import;
        }
    }
}

1;

__END__

=head1 NAME

App::plmetrics - show the Perl metrics


=head1 SYNOPSIS

    use App::plmetrics;
    my $plm = App::plmetrics->new->run;


=head1 DESCRIPTION

App::plmetrics is ths module for checking metrics.

See L<plmetrics> command.


=head1 METHODS

=head2 new

constractor

=head2 opt

getter for command options

=head2 run

execute


=head1 REPOSITORY

App::plmetrics is hosted on github
<http://github.com/bayashi/App-plmetrics>

Welcome your patches and issues :D


=head1 AUTHOR

Dai Okabayashi E<lt>bayashi@cpan.orgE<gt>


=head1 SEE ALSO

L<plmetrics>


=head1 LICENSE

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.

=cut

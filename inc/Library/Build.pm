package Library::Build;

use 5.006;
use strict;
use warnings;

our $VERSION = 0.002;

use autodie;
use Carp 'croak';
use Config;
use ExtUtils::CBuilder;
use File::Copy qw/copy/;
use File::Path qw/mkpath rmtree/;
use File::Basename qw/dirname/;
use List::MoreUtils qw/any first_index/;
use POSIX qw/strftime/;
use Readonly;
use TAP::Harness;

Readonly my $compiler => $Config{cc} eq 'cl' ? 'msvc' : 'gcc';
Readonly my $NOTFOUND => -1;
Readonly my $SECURE   => oct 744;

sub cc_flags {
	if ($compiler eq 'gcc') {
		return qw/--std=gnu++0x -ggdb3 -DDEBUG -Wall -Wshadow -Wnon-virtual-dtor -Wsign-promo -Wextra -Winvalid-pch/;
	}
	elsif ($compiler eq 'msvc') {
		return qw{/TP /EHsc /Wall};
	}
}

sub parse_line {
	my ($action, $line) = @_;

	for ($line) {
		next if / ^ \# /xms;
		s{ \n \s+ }{ }x;
		next if / ^ \s* $ /xms;


		if (my ($name, $args) = m/ \A \s* (\* | \w+ ) \s+ (.*?) \s* \z /xms) {
			my @args = split /\s+/, $args;
			return @args if $name eq $action or $name eq '*';
		}
		else {
			croak "Can't parse line '$_'";
		}
	}
	return;
}

sub read_config {
	my $action = shift;

	my @ret;
	
	my @files = (
		($ENV{MODULEBUILDRC} ? $ENV{MODULEBUILDRC}               : ()), 
		($ENV{HOME} ?          "$ENV{HOME}/.modulebuildrc"       : ()), 
		($ENV{USERPROFILE} ?   "$ENV{USERPROFILE}/.modulebuldrc" : ()),
	);
	FILE:
	for my $file (@files) {
		next FILE if not -e $file;

		open my $fh, '<', $file or croak "Couldn't open configuration file '$file': $!";
		my @lines = split / \n (?! \s) /xms, do { local $/ = undef, <$fh> };
		close $fh;
		for my $line (@lines) {
			push @ret, parse_line($action, $line);
		}
	}
	return @ret;
}

sub parse_action {
	my $meta_arguments = shift;
	for my $meta_argument ( map { $meta_arguments->{$_} } qw/argv envs/ ) {
		my $position = first_index { not m/ ^ -- /xms and not m/=/xms } @{$meta_argument};
		return splice @{$meta_argument}, $position, 1 if $position != $NOTFOUND;
	}
	return;
}

sub parse_option {
	my ($options, $argument) = @_;
	$argument =~ s/ ^ -- //xms;
	if ($argument =~ / \A (\w+) = (.*) \z /xms) {
		$options->{$1} = $2;
	}
	else {
		$options->{$argument} = 1;
	}
	return;
}

sub parse_options {
	my %meta_arguments = @_;
	@{ $meta_arguments{envs} } = split / /, $ENV{PERL_MB_OPT} if $ENV{PERL_MB_OPT};

	my %options = (
		quiet   => 0,
		version => delete $meta_arguments{version},
	);

	$options{action} = parse_action(\%meta_arguments) || 'build';

	@{ $meta_arguments{config} } = read_config($options{action});

	for my $argument_list (map { $meta_arguments{$_} } qw/config cached envs argv/) {
		for my $argument (@{ $argument_list }) {
			parse_option(\%options, $argument);
		}
	}
	$options{quiet} = -$options{verbose} if not $options{quiet} and $options{verbose};
	return %options;
}

sub get_input_files {
	my $library = shift;
	if ($library->{input_files}) {
		if (ref $library->{input_files}) {
			return @{ $library->{input_files} };
		}
		else {
			return $library->{input_files}
		}
	}
	elsif ($library->{input_dir}){
		opendir my $dh, $library->{input_dir};
		my @ret = grep { /^ .+ \. C $/xsm } readdir $dh;
		closedir $dh;
		return @ret;
	}
}

sub linker_flags {
	my ($libs, $libdirs, %options) = @_;
	my @elements;
	if ($compiler eq 'gcc') {
		push @elements, map { "-l$_" } @{$libs};
		push @elements, map { "-L$_" } @{$libdirs};
		if ($options{'C++'}) {
			push @elements, '-lstdc++';
		}
	}
	elsif ($compiler eq 'msvc') {
		push @elements, map { "$_.dll" } @{$libs};
		push @elements, map { qq{-libpath:"$_"} } @{$libdirs};
		if ($options{'C++'}) {
			push @elements, 'msvcprt.lib';
		}
	}
	push @elements, $options{append} if defined $options{append};
	return join ' ', @elements;
}

use namespace::clean;

sub include_dirs {
	my ($self, $extra) = @_;
	return [ ( defined $self->{include_dirs} ? split(/:/, $self->{include_dirs}) : () ), (defined $extra ? @{$extra} : () ) ];
}

my %default_actions = (
);

sub new {
	my ($class, %meta) = @_;
	my %options = parse_options(%meta);
	my $self = bless {
		%options,
		builder => ExtUtils::CBuilder->new(quiet => $options{quiet}),
	}, $class;
	$self->register_actions(%default_actions);
	return $self;
}

sub create_by_system {
	my ($self, $exec, $input, $output) = @_;
	if (not -e $output or -M $input < -M $output) {
		my @call = (@{$exec}, $input);
		print "@call\n" if $self->{quiet} <= 0;
		my $pid = fork;
		if ($pid) {
			waitpid $pid, 0;
		}
		else {
			open STDOUT, '>', $output;
			exec @call;
		}
	}
	return;
}

sub process_cpp {
	my ($self, $input, $output) = @_;
	$self->create_by_system( [ $Config{cpp}, split(/ /, $Config{ccflags}), "-I$Config{archlibexp}/CORE" ], $input, $output);
	return;
}

sub process_perl {
	my ($self, $input, $output) = @_;
	$self->create_by_system( [ $^X, '-T' ], $input, $output);
	return;
}

sub create_dir {
	my ($self, @dirs) = @_;
	mkpath(\@dirs, $self->{quiet} <= 0, $SECURE);
	return;
}

sub copy_files {
	my ($self, $source, $destination) = @_;
	if (-d $source) {
		$self->create_dir($destination);
		opendir my $dh, $source or croak "Can't open dir $source: $!";
		for my $filename (readdir $dh) {
			next if $filename =~ / \A \. /xms;
			$self->copy_files("$source/$filename", "$destination/$filename");
		}
	}
	elsif (-f $source) {
		$self->create_dir(dirname($destination));
		if (not -e $destination or -M $source < -M $destination) {
			copy($source, $destination) or croak "Could not copy '$source' to '$destination': $!";
			print "cp $source $destination\n" if $self->{quiet} <= 0;
		}
	}
	return;
}

sub build_library {
	my ($self, $library_name, $library_ref) = @_;
	my %library    = %{ $library_ref };
	my @raw_files  = get_input_files($library_ref);
	my $input_dir  = $library{input_dir}  || '.';
	my $output_dir = $library{output_dir} || 'blib';
	my $tempdir    = $library{temp_dir}   || '_build';
	my %object_for = map { ( "$input_dir/$_" => "$tempdir/".$self->{builder}->object_file($_) ) } @raw_files;
	for my $source_file (sort keys %object_for) {
		my $object_file = $object_for{$source_file};
		next if -e $object_file and -M $source_file > -M $object_file;
		$self->{builder}->compile(
			source               => $source_file,
			object_file          => $object_file,
			'C++'                => $library{'C++'},
			include_dirs         => $self->include_dirs($library{include_dirs}),
			extra_compiler_flags => $library{cc_flags} || [ cc_flags ],
		);
	}
	my $library_file = $library{libfile} || "$output_dir/arch/lib".$self->{builder}->lib_file($library_name);
	my $linker_flags = linker_flags($library{libs}, $library{libdirs}, append => $library{linker_append}, 'C++' => $library{'C++'});
	$self->{builder}->link(
		lib_file           => $library_file,
		objects            => [ values %object_for ],
		extra_linker_flags => $linker_flags,
		module_name        => 'libperl++',
	) if not -e $library_file or any { (-M $_ < -M $library_file ) } values %object_for;
	return;
}

sub build_executable {
	my ($self, $prog_source, $prog_exec, %args) = @_;
	my $prog_object = $args{object_file} || $self->{builder}->object_file($prog_source);
	my $linker_flags = linker_flags($args{libs}, $args{libdirs}, append => $args{linker_append}, 'C++' => $args{'C++'});
	$self->{builder}->compile(
		source               => $prog_source,
		object_file          => $prog_object,
		extra_compiler_flags => [ cc_flags ],
		%args,
		include_dirs         => $self->include_dirs($args{include_dirs}),
	) if not -e $prog_object or -M $prog_source < -M $prog_object;

	$self->{builder}->link_executable(
		objects            => $prog_object,
		exe_file           => $prog_exec,
		extra_linker_flags => $linker_flags,
		%args,
	) if not -e $prog_exec or -M $prog_object < -M $prog_exec;
	return;
}

sub run_tests {
	my ($self, @test_goals) = @_;
	my $library_var = $self->{library_var} || $Config{ldlibpthname};
	local $ENV{$library_var} = 'blib/arch';
	printf "Report %s\n", strftime('%y%m%d-%H:%M', localtime) if $self->{quiet} < 2;
	my $harness = TAP::Harness->new({ 
		verbosity => -$self->{quiet},
		exec => sub {
			my (undef, $file) = @_;
			return [ $file ];
		},
		merge => 1,
	});

	return $harness->runtests(@test_goals);
}

sub remove_tree {
	my ($self, @files) = @_;
	rmtree(\@files, $self->{quiet} <= 0, 0);
	return;
}

sub register_actions {
	my ($self, %action_map) = @_;
	while (my ($name, $sub) = each %action_map) {
		$self->{action_map}{$name} = $sub;
	}
	return;
}

sub dispatch {
	my $self = shift;
	my $action_name = shift || $self->{action} || croak 'No action defined';
	my $action_sub = $self->{action_map}{$action_name} or croak "No action '$action_name' defined";
	return $action_sub->($self);
}

1;

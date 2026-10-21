#!/usr/bin/env perl
# Proves that the reset-credentials addon rotates both keys under the
# environment's secrets base through the environment's vault target, and
# that it tells a cluster to stop every node before the deploy that applies
# the new keys, because a rolling deploy cannot.
#
# Each case hands the hook a stub environment and replaces Genesis::run, so
# the test sees every safe command without running one.  Run it with
# `prove spec/hooks` or `perl spec/hooks/addon-reset-credentials.t`.

use v5.20;
use warnings;

use Cwd qw/abs_path/;
use File::Basename qw/dirname/;
use Test::More;

BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

my $hooks = abs_path(dirname(__FILE__).'/../../hooks');
require "$hooks/addon-reset-credentials~r.pm";

my $class = 'Genesis::Hook::Addon::RustFS::ResetCredentials';

# Capture what the hook prints and runs, and turn bail into a die that the
# test can catch, instead of sending either through Genesis.
my (@printed, @ran, $run_rc);
{
	no strict 'refs';
	no warnings 'redefine';
	*{"${class}::info"} = sub {
		my ($fmt, @args) = @_;
		$fmt = '' unless defined($fmt);
		push @printed, @args ? sprintf($fmt, @args) : $fmt;
	};
	*{"${class}::bail"} = sub {
		my ($fmt, @args) = @_;
		die((@args ? sprintf($fmt, @args) : $fmt) . "\n");
	};
	*{"${class}::run"} = sub {
		my ($opts, @cmd) = @_;
		push @ran, join(' ', @cmd);
		return ('', $run_rc);
	};
}

package StubVault {
	sub new { bless {}, shift }
	sub name { 'spec-vault' }
}

package StubEnv {
	sub new { my ($c, %o) = @_; bless {%o}, $c }
	sub name { 'spec-lab' }
	sub secrets_base { '/secret/spec/lab/rustfs/' }
	sub vault { StubVault->new }
	sub exodus_lookup {
		my ($self, $key, $default) = @_;
		return exists($self->{exodus}{$key}) ? $self->{exodus}{$key} : $default;
	}
}

package main;

# run_hook runs perform with the given answer on stdin, and returns the
# hook result (or the bail text) and what it printed.
sub run_hook {
	my (%o) = @_;
	@printed = (); @ran = (); $run_rc = $o{run_rc} // 0;
	my $answer = $o{answer} // "YES\n";
	open(my $in, '<', \$answer) or die "cannot open stdin: $!";
	local *STDIN = $in;
	my $hook = bless {env => StubEnv->new(exodus => $o{exodus} // {}), complete => 0}, $class;
	my $result;
	{
		local *STDOUT;
		open(STDOUT, '>', \my $prompt) or die "cannot capture stdout: $!";
		$result = eval { $hook->perform };
	}
	return ($result, $@, join("\n", @printed));
}

{
	my ($result, $error, $out) = run_hook(exodus => {instances => 1});
	is($error, '', 'a single node rotates') or diag $error;
	is_deeply(\@ran, [
		'safe -T spec-vault gen -l 20 /secret/spec/lab/rustfs/credentials:access_key',
		'safe -T spec-vault gen -l 40 /secret/spec/lab/rustfs/credentials:secret_key',
	], 'both keys rotate under the secrets base through the vault target');
	like($out, qr/^  #G\{genesis deploy spec-lab\}$/m, 'a single node only needs a deploy');
	unlike($out, qr/bosh stop/, 'a single node is not told to stop first');
}

{
	my ($result, $error, $out) = run_hook(exodus => {cluster => 1, instances => 3});
	is($error, '', 'a cluster rotates') or diag $error;
	is(scalar(@ran), 2, 'a cluster rotates both keys');
	like($out, qr/every node must restart with the new credentials at\nthe same time/, 'the warning says why before the prompt');
	like($out, qr/#G\{genesis spec-lab bosh stop --skip-drain rustfs\}\n  #G\{genesis deploy spec-lab\}\n  #G\{genesis spec-lab bosh start rustfs\}/,
		'a cluster is told to stop, deploy, and start, in that order');
}

{
	my ($result, $error, $out) = run_hook(exodus => {instances => 3});
	like($out, qr/bosh stop --skip-drain rustfs/, 'an instance count above one also counts as a cluster');
}

{
	my ($result, $error) = run_hook(answer => "no\n");
	like($error, qr/aborted by operator/, 'anything but YES aborts');
	is(scalar(@ran), 0, 'an aborted rotation runs nothing');
}

{
	my ($result, $error) = run_hook(run_rc => 1);
	like($error, qr/Failed to rotate access_key \(exit 1\)/, 'a failing safe stops the addon');
	is(scalar(@ran), 1, 'the secret key is left alone when the access key fails');
}

done_testing;

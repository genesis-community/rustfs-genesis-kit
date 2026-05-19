package Genesis::Hook::Info::RustFS v0.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook);

use Genesis qw/bail info/;

# init - Initialize the hook {{{
sub init {
	my ($class, %ops) = @_;
	my $obj = $class->SUPER::init(%ops);
	$obj->check_minimum_genesis_version('3.1.0');
	return $obj;
}
# }}}

# perform - Main hook execution {{{
sub perform {
	my ($self) = @_;

	my $exodus = $self->env->exodus_lookup('/') || {};

	my $s3_api_url     = $exodus->{s3_api_url}     || '(not set)';
	my $s3_console_url = $exodus->{s3_console_url}  || '(not set)';

	# Instance count: prefer exodus (post-deploy truth), then params, then default 1
	my $instance_count = $exodus->{instances}
		|| $self->env->lookup('params.instances', 1);

	my $cluster_mode = ($instance_count > 1) ? 'yes' : 'no';

	my $vault_path = $self->env->vault_path;

	info("RustFS Info:");
	info("  S3 API URL:     %s", $s3_api_url);
	info("  Console URL:    %s", $s3_console_url);
	info("  Instance count: %s", $instance_count);
	info("  Cluster mode:   %s", $cluster_mode);
	info("  Access key:     (stored in vault at %s/credentials/access_key)", $vault_path);

	return $self->done(1);
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:

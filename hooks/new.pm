package Genesis::Hook::New::RustFS v0.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook);

use Genesis qw/bail/;
use Genesis::UI qw/prompt_for_line prompt_for_list/;

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

	my $instances = prompt_for_line(
		'How many RustFS nodes? (1 = single-node, 3+ = cluster)',
		'instances', '1',
		qr/^[1-9]\d*$/, 'must be a positive integer'
	);

	my $rustfs_network = prompt_for_line(
		'Network name for RustFS instances:',
		'network', 'rustfs',
	);

	my $rustfs_vm_type = prompt_for_line(
		'VM type for RustFS instances:',
		'vm_type', 'default',
	);

	my $rustfs_disk_type = prompt_for_line(
		'Persistent disk type for RustFS instances:',
		'disk_type', 'default',
	);

	my @azs = prompt_for_list(
		'line',
		'Availability zones',
		'az',
		1, undef,
	);
	@azs = qw/z1 z2 z3/ unless @azs;

	my $file_content = "---\n";
	$file_content .= "kit:\n";
	$file_content .= "  name:    $ENV{GENESIS_KIT_NAME}\n";
	$file_content .= "  version: $ENV{GENESIS_KIT_VERSION}\n";
	$file_content .= "\n";
	$file_content .= $self->env->genesis_config_block;
	$file_content .= "\n";
	$file_content .= "params:\n";
	$file_content .= "  instances:        $instances\n";
	$file_content .= "  rustfs_network:   $rustfs_network\n";
	$file_content .= "  rustfs_vm_type:   $rustfs_vm_type\n";
	$file_content .= "  rustfs_disk_type: $rustfs_disk_type\n";
	$file_content .= "  availability_zones:\n";
	$file_content .= "  - $_\n" for @azs;

	# route-registrar-specific prompts
	if ($self->want_feature('route-registrar')) {
		my $system_domain = prompt_for_line(
			'CF system domain (e.g. system.example.com):',
			'system_domain',
		);
		my $api_route_prefix = prompt_for_line(
			'Route prefix for S3 API endpoint:',
			'api_route_prefix', 's3-api',
		);
		my $console_route_prefix = prompt_for_line(
			'Route prefix for S3 console endpoint:',
			'console_route_prefix', 's3-console',
		);
		$file_content .= "  system_domain:        $system_domain\n";
		$file_content .= "  api_route_prefix:     $api_route_prefix\n";
		$file_content .= "  console_route_prefix: $console_route_prefix\n";
	}

	$self->env->write_manifest($file_content);

	return $self->done();
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:

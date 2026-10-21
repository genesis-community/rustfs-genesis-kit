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

	# Two nodes stop writing when either one is down, so the kit refuses
	# them, and the prompt does too.
	my $instances = prompt_for_line(
		'How many RustFS nodes? (1 = single-node, 3+ = cluster)',
		'instances', '1',
		qr/^(?:1|[3-9]|[1-9]\d+)$/, 'must be 1, or 3 or more'
	);

	my $file_content = "---\n";
	$file_content .= "kit:\n";
	$file_content .= "  name:    $ENV{GENESIS_KIT_NAME}\n";
	$file_content .= "  version: $ENV{GENESIS_KIT_VERSION}\n";
	$file_content .= "\n";
	$file_content .= $self->env->genesis_config_block;
	$file_content .= "\n";
	$file_content .= "params:\n";

	if ($self->want_feature('ocfp')) {
		# Under ocfp the subnet reservations supply the addresses, network, VM
		# type, and disk type, and params.ocfp_instances picks how many of the
		# reserved addresses to use.
		$file_content .= "  ocfp_instances: $instances\n";
	} else {
		$file_content .= $self->_standalone_params($instances);
	}

	# route-registrar-specific prompts
	if ($self->want_feature('route-registrar')) {
		my $api_route_prefix = prompt_for_line(
			'Route prefix for S3 API endpoint:',
			'api_route_prefix', 's3-api',
		);
		my $console_route_prefix = prompt_for_line(
			'Route prefix for S3 console endpoint:',
			'console_route_prefix', 's3-console',
		);
		$file_content .= "  api_route_prefix:     $api_route_prefix\n";
		$file_content .= "  console_route_prefix: $console_route_prefix\n";
	}

	$self->env->write_manifest($file_content);

	return $self->done();
}
# }}}

# _standalone_params - the node parameters outside ocfp {{{
# Peers verify each other's certificate by IP address, so a cluster needs
# params.ips.  A single node may leave it out, but then its certificate
# names only 127.0.0.1, so we ask for it there too.
sub _standalone_params {
	my ($self, $instances) = @_;

	my $ips = prompt_for_list(
		'line',
		$instances > 1
			? "Static IP address of each of the $instances RustFS nodes"
			: 'Static IP address of the RustFS node (clients that verify the certificate need it)',
		'IP address',
		$instances > 1 ? $instances : 0, $instances,
		qr/^[0-9A-Fa-f:.]+$/, 'must be an IPv4 or IPv6 address',
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

	my $azs = prompt_for_list(
		'line',
		'Availability zones',
		'az',
		1, undef,
	);
	my @azs = @$azs ? @$azs : qw/z1 z2 z3/;

	# The kit deploys one node per address, so params.instances is written
	# only when there are no addresses.
	my $content = '';
	if (@$ips) {
		$content .= "  ips:\n";
		$content .= "  - $_\n" for @$ips;
	} else {
		$content .= "  instances:        $instances\n";
	}
	$content .= "  rustfs_network:   $rustfs_network\n";
	$content .= "  rustfs_vm_type:   $rustfs_vm_type\n";
	$content .= "  rustfs_disk_type: $rustfs_disk_type\n";
	$content .= "  availability_zones:\n";
	$content .= "  - $_\n" for @azs;
	return $content;
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:

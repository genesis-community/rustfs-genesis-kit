package Genesis::Hook::New::RustFS v0.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook);

use Genesis qw/bail/;
use Genesis::UI qw/prompt_for_boolean prompt_for_integer prompt_for_string prompt_for_list/;

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

	my $instances = prompt_for_integer(
		'How many RustFS nodes? (1 = single-node, 3+ = cluster)',
		default => 1,
		min     => 1,
	);

	my $rustfs_network = prompt_for_string(
		'Network name for RustFS instances:',
		default => 'rustfs',
	);

	my $rustfs_vm_type = prompt_for_string(
		'VM type for RustFS instances:',
		default => 'default',
	);

	my $rustfs_disk_type = prompt_for_string(
		'Persistent disk type for RustFS instances:',
		default => 'default',
	);

	my @azs = prompt_for_list(
		'Availability zones (space-separated):',
		default => [qw/z1 z2 z3/],
	);

	my $file_content = "---\n";
	$file_content .= "kit:\n";
	$file_content .= "  name:    $ENV{GENESIS_KIT_NAME}\n";
	$file_content .= "  version: $ENV{GENESIS_KIT_VERSION}\n";
	$file_content .= "\n";
	$file_content .= $self->env->genesis_config_block;
	$file_content .= "\n";
	$file_content .= "params:\n";
	$file_content .= "  instances:            $instances\n";
	$file_content .= "  rustfs_network:       $rustfs_network\n";
	$file_content .= "  rustfs_vm_type:       $rustfs_vm_type\n";
	$file_content .= "  rustfs_disk_type:     $rustfs_disk_type\n";
	$file_content .= "  availability_zones:\n";
	$file_content .= "  - $_\n" for @azs;

	# route-registrar-specific prompts
	if ($self->want_feature('route-registrar')) {
		my $system_domain = prompt_for_string(
			'CF system domain (e.g. system.example.com):',
		);
		my $api_route_prefix = prompt_for_string(
			'Route prefix for S3 API endpoint:',
			default => 's3-api',
		);
		my $console_route_prefix = prompt_for_string(
			'Route prefix for S3 console endpoint:',
			default => 's3-console',
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

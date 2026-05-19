package Genesis::Hook::Addon::RustFS::Mc v0.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Addon);
use Genesis qw/info run bail/;

# init - Initialize the hook {{{
sub init {
  my $class = shift;
  my $obj = $class->SUPER::init(@_);
  $obj->check_minimum_genesis_version('3.1.0');
  return $obj;
}
# }}}

# cmd_details - Short description shown in genesis do --list {{{
sub cmd_details {
  return
    "Print mc (MinIO client) alias setup command populated with cluster credentials.\n".
    "Requires mc to be installed locally (https://min.io/docs/minio/linux/reference/minio-mc.html).";
}
# }}}

# perform - Main hook execution {{{
sub perform {
  my ($self) = @_;
  return 1 if $self->completed;

  my $env      = $self->env;
  my $env_name = $env->name;
  my $vault_path = $env->vault_path_prefix;

  # Read credentials and endpoint from exodus / vault
  my $s3_api_url = $self->_exodus_value('s3_api_url');
  bail(
    "Could not read s3_api_url from exodus for environment %s.\n".
    "Ensure the environment has been deployed at least once.",
    $env_name
  ) unless $s3_api_url;

  my $access_key = $self->_exodus_value('access_key');
  bail(
    "Could not read access_key from exodus for environment %s.",
    $env_name
  ) unless $access_key;

  # secret_key is not written to exodus (sensitive) - read direct from vault
  my ($secret_key, $sk_rc) = run(
    { stderr => 0 },
    'safe', '-T', $env_name,
    'get', "$vault_path/credentials/secret_key"
  );
  bail(
    "Could not read secret_key from Vault path %s/credentials/secret_key.\n".
    "Ensure you are authenticated: safe -T %s auth",
    $vault_path, $env_name
  ) unless $sk_rc == 0 && $secret_key;
  chomp $secret_key;

  my $alias = "rustfs-$env_name";
  $alias =~ s/[^A-Za-z0-9_-]/-/g;

  info("");
  info("#M{RustFS mc setup for environment: %s}", $env_name);
  info("");
  info("Run the following to configure mc:");
  info("");
  info("  #G{mc alias set %s %s %s %s --insecure}",
    $alias, $s3_api_url, $access_key, $secret_key);
  info("");
  info("Common mc commands (using alias #C{%s}):", $alias);
  info("");
  info("  List buckets:");
  info("    #G{mc ls %s}", $alias);
  info("");
  info("  Create a bucket:");
  info("    #G{mc mb %s/<bucket-name>}", $alias);
  info("");
  info("  Upload a file:");
  info("    #G{mc cp <local-file> %s/<bucket-name>/}", $alias);
  info("");
  info("  Download a file:");
  info("    #G{mc cp %s/<bucket-name>/<file> <local-dest>}", $alias);
  info("");
  info("  Remove a bucket (recursive):");
  info("    #G{mc rb --force %s/<bucket-name>}", $alias);
  info("");
  info("  Show cluster info:");
  info("    #G{mc admin info %s}", $alias);
  info("");
  info("#Y{Note}: Use --insecure if the API TLS certificate is self-signed.");
  info("         To trust the CA instead:");
  info("    #G{mc alias set %s %s %s %s --capath <path-to-ca.crt>}",
    $alias, $s3_api_url, $access_key, $secret_key);
  info("");

  return $self->done(1);
}
# }}}

# _exodus_value - Read a single key from genesis exodus data {{{
sub _exodus_value {
  my ($self, $key) = @_;

  my ($out, $rc) = run(
    { stderr => 0 },
    'safe', '-T', $ENV{GENESIS_ENVIRONMENT},
    'get', "$ENV{GENESIS_EXODUS_MOUNT}:$key"
  );
  return undef unless $rc == 0 && defined $out;
  chomp $out;
  return $out;
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:

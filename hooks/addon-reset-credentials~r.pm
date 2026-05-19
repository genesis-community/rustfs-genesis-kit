package Genesis::Hook::Addon::RustFS::ResetCredentials v0.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Addon);
use Genesis qw/info bail run/;

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
    "Regenerate the RustFS access_key and secret_key in Vault, then redeploy.\n".
    "Prints the safe commands and prompts for confirmation before rotating.";
}
# }}}

# perform - Main hook execution {{{
sub perform {
  my ($self) = @_;
  return 1 if $self->completed;

  my $env        = $self->env;
  my $env_name   = $env->name;
  my $vault_path = $env->vault_path_prefix;

  my $access_key_path = "$vault_path/credentials/access_key";
  my $secret_key_path = "$vault_path/credentials/secret_key";

  info("");
  info("#Y{WARNING}: This will rotate RustFS credentials and trigger a redeploy.");
  info("");
  info("Vault paths that will be regenerated:");
  info("  #C{%s}", $access_key_path);
  info("  #C{%s}", $secret_key_path);
  info("");
  info("Equivalent safe commands:");
  info("  safe -T %s gen %s", $env_name, $access_key_path);
  info("  safe -T %s gen %s", $env_name, $secret_key_path);
  info("");

  # Prompt operator - abort if not confirmed
  print "Type YES to confirm credential rotation (anything else aborts): ";
  my $answer = <STDIN>;
  chomp($answer // '');

  bail("Credential rotation aborted by operator.") unless $answer eq 'YES';

  info("");
  info("Rotating #C{access_key}...");
  my ($out, $rc) = run(
    { stderr => 1 },
    'safe', '-T', $env_name, 'gen', '-l', '20', "$access_key_path"
  );
  bail("Failed to rotate access_key (exit %d): %s", $rc, $out) unless $rc == 0;
  info("  #g{[ok]} access_key rotated");

  info("Rotating #C{secret_key}...");
  ($out, $rc) = run(
    { stderr => 1 },
    'safe', '-T', $env_name, 'gen', '-l', '40', "$secret_key_path"
  );
  bail("Failed to rotate secret_key (exit %d): %s", $rc, $out) unless $rc == 0;
  info("  #g{[ok]} secret_key rotated");

  info("");
  info("Credentials rotated. Redeploy to apply new credentials:");
  info("  #G{genesis deploy %s}", $env_name);
  info("");
  info("#Y{Note}: Existing S3 clients will fail authentication until the redeploy completes.");

  return $self->done(1);
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:

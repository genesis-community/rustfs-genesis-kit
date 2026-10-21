package Genesis::Hook::Addon::RustFS::ResetCredentials v0.2.0;

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
  my $target     = $env->vault->name;

  my $access_key_path = $env->secrets_base . 'credentials:access_key';
  my $secret_key_path = $env->secrets_base . 'credentials:secret_key';

  # RustFS nodes authenticate to each other with the root credentials, so a
  # node that restarts with new ones cannot rejoin peers that still hold the
  # old ones, and a rolling deploy stops at the first node.  A cluster has
  # to stop every node, deploy while they are stopped, and start them again.
  my $instances = $env->exodus_lookup('instances', 1);
  my $cluster = $env->exodus_lookup('cluster', 0) || ($instances =~ /^\d+$/ && $instances > 1);

  info("");
  info("#Y{WARNING}: This will rotate RustFS credentials, and they take effect on the next deploy.");
  if ($cluster) {
    info("");
    info("This is a cluster, so every node must restart with the new credentials at");
    info("the same time, and the cluster serves nothing for a few minutes. A rolling");
    info("deploy cannot apply them, because a node with new credentials cannot rejoin");
    info("peers that still hold the old ones.");
  }
  info("");
  info("Vault paths that will be regenerated:");
  info("  #C{%s}", $access_key_path);
  info("  #C{%s}", $secret_key_path);
  info("");
  info("Equivalent safe commands:");
  info("  safe -T %s gen -l 20 %s", $target, $access_key_path);
  info("  safe -T %s gen -l 40 %s", $target, $secret_key_path);
  info("");

  # Prompt operator - abort if not confirmed
  print "Type YES to confirm credential rotation (anything else aborts): ";
  my $answer = <STDIN>;
  $answer //= '';
  chomp $answer;

  bail("Credential rotation aborted by operator.") unless $answer eq 'YES';

  info("");
  info("Rotating #C{access_key}...");
  my ($out, $rc) = run(
    { stderr => 1 },
    'safe', '-T', $target, 'gen', '-l', '20', "$access_key_path"
  );
  bail("Failed to rotate access_key (exit %d): %s", $rc, $out) unless $rc == 0;
  info("  #g{[ok]} access_key rotated");

  info("Rotating #C{secret_key}...");
  ($out, $rc) = run(
    { stderr => 1 },
    'safe', '-T', $target, 'gen', '-l', '40', "$secret_key_path"
  );
  bail("Failed to rotate secret_key (exit %d): %s", $rc, $out) unless $rc == 0;
  info("  #g{[ok]} secret_key rotated");

  info("");
  if ($cluster) {
    info("Credentials rotated. Apply them by stopping every node, deploying while the");
    info("nodes are stopped, and starting them again:");
    info("");
    info("  #G{genesis %s bosh stop --skip-drain rustfs}", $env_name);
    info("  #G{genesis deploy %s}", $env_name);
    info("  #G{genesis %s bosh start rustfs}", $env_name);
    info("");
    info("Do not run the deploy while the nodes are running. Its first node would fail");
    info("post-start, and BOSH then refuses to stop the deployment until a deploy succeeds.");
  } else {
    info("Credentials rotated. Redeploy to apply new credentials:");
    info("  #G{genesis deploy %s}", $env_name);
  }
  info("");
  info("#Y{Note}: Existing S3 clients will fail authentication until the redeploy completes.");

  return $self->done(1);
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:

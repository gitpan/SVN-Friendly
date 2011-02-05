use strict;
use warnings;

package SVN::Friendly::Utils;
my $CLASS = __PACKAGE__;

#--------------------------------------------------------------------

use Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK=qw(_shiftBoolean _shiftVisitor);

#--------------------------------------------------------------------

our $NOOP = sub { return 0; };


#==================================================================
# FUNCTIONS - for use internally within SVN::Friendly
#==================================================================

#----------------------------------------------------------------

sub _shiftBoolean {
  my $xArg = shift @{shift @_};
  return defined($xArg) ? $xArg : 0;
}

#----------------------------------------------------------------

sub _shiftVisitor {
  my ($aArgs) = @_;

  #some of the subversion API methods cause a segmentation fault
  #unless they are passed some sort of visitor, even if that
  #visitor is only a NOOP

  my $crVisit = shift @$aArgs;
  return defined($crVisit) ? $crVisit : $NOOP;
}

#==================================================================
# MODULE INITIALIZATION
#==================================================================

1;

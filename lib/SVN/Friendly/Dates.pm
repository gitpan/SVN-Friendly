use strict;
use warnings;

package SVN::Friendly::Dates;
my $CLASS = __PACKAGE__;

#--------------------------------------------------------------------

use Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK=qw(getTimestampFromISO8601
                  getTimestamp
                  getLocalNanoTime
                  getLocalPerlTime
                  getLocalUsecTime
                  getUtcNanoTime
                  getUtcPerlTime
                 );

#--------------------------------------------------------------------

use SVN::Core;
use Time::Local qw(timelocal_nocheck);

use constant {
  DAY => 1
 , MINUTE => 2
 , SECOND => 3
 , USEC => 4
};

#==================================================================
# FUNCTIONS
#==================================================================

#--------------------------------------------------------------------

sub getTimestampFromISO8601($;$) {
  my ($sISO, $iPrecision) = @_;
  if (defined($iPrecision)) {
    if ($iPrecision == DAY) {
      $sISO =~ s/^([^T]+)T.*$/$1/;
    } elsif ($iPrecision == MINUTE) {
      $sISO =~ s/^([^T]+)T(\d\d:\d\d).*$/$1 $2 UTC/;
    } elsif ($iPrecision == SECOND) {
      $sISO =~ s/^([^T]+)T([^.]+)\.\d{6}.*$/$1 $2 UTC/;
    } elsif ($iPrecision == USEC) {
      $sISO =~ s/^([^T]+)T([^.]+\.\d{6}).*$/$1 $2 UTC/;
    }
  }
  return $sISO;
}
#--------------------------------------------------------------------

sub getTimestamp($;$) {
  my ($iAprTime, $iPrecision) = @_;
  $iPrecision = USEC unless defined($iPrecision);

  return getTimestampFromISO8601
    (SVN::Core::time_to_cstring($iAprTime), $iPrecision);
}

#--------------------------------------------------------------------

sub getLocalNanoTime($) {
  my $iAprTime = $_[0];
  return getLocalUsecTime($iAprTime)*1000;
}

#--------------------------------------------------------------------

sub getLocalPerlTime($) {
  my $iAprTime = $_[0];
  return int(getLocalUsecTime($iAprTime)/1000000);
}

#--------------------------------------------------------------------

sub getLocalUsecTime($) {
  my $iAprTime = $_[0];
  return ($iAprTime + 1000000* timelocal_nocheck(0,0,0,1,0,1970));
}

#--------------------------------------------------------------------

sub getUtcNanoTime($) {
  my $iAprTime = $_[0];
  return return $iAprTime*1000;
}

#--------------------------------------------------------------------

sub getUtcPerlTime($) {
  my $iAprTime = $_[0];
  return int($iAprTime/1000000);
}

#==================================================================
# PRIVATE
#==================================================================


#==================================================================
# MODULE INITIALIZATION
#==================================================================

1;

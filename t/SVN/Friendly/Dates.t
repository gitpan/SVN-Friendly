use strict;
use warnings;
use Test::More tests => 10;

#------------------------------------------------------------------

BEGIN { use_ok('SVN::Friendly::Dates') or BAIL_OUT; };
my $DATE_CLASS = "SVN::Friendly::Dates";
my $TEST_CLASS = $DATE_CLASS;

#------------------------------------------------------------------

#==================================================================
# TEST SUITES
#==================================================================

#==================================================================
# SUBTESTS
#==================================================================

sub testAprDate {
  my ($sName, $iAprDate, $iNano, $iPerl, $hISO
     , $iLocalSec, $iLocalMicro, $iLocalNano) = @_;

  is(SVN::Friendly::Dates::getUtcNanoTime($iAprDate), $iNano
     , "$sName: getUtcNanoTime");
  is(SVN::Friendly::Dates::getUtcPerlTime($iAprDate), $iPerl
     , "$sName: getUtcPerlTime");
  is(SVN::Friendly::Dates::getLocalPerlTime($iAprDate), $iLocalSec
     , "$sName: getLocalPerlTime");
  is(SVN::Friendly::Dates::getLocalUsecTime($iAprDate), $iLocalMicro
     , "$sName: getLocalUsecTime");
  is(SVN::Friendly::Dates::getLocalNanoTime($iAprDate), $iLocalNano
     , "$sName: getLocalNanoTime");


  foreach my $k ($DATE_CLASS->DAY, $DATE_CLASS->MINUTE
                 , $DATE_CLASS->SECOND, $DATE_CLASS->USEC) {
    my $v = $hISO->{$k};
    is(SVN::Friendly::Dates::getTimestamp($iAprDate, $k), $v
       , "$sName: getISO8601Time($iAprDate, $k)");
  }
}

#==================================================================
# TEST PLAN
#==================================================================

use Time::Local;
my $iLocalEpoch = Time::Local::timelocal_nocheck(0,0,0,1,0,1970);

testAprDate('epoch', 0
   => 0, 0, { $DATE_CLASS->DAY => '1970-01-01'
              ,$DATE_CLASS->MINUTE => '1970-01-01 00:00 UTC'
              ,$DATE_CLASS->SECOND => '1970-01-01 00:00:00 UTC'
              ,$DATE_CLASS->USEC => '1970-01-01 00:00:00.000000 UTC'
            }
   , $iLocalEpoch, $iLocalEpoch*10**6, $iLocalEpoch*10**9
   );

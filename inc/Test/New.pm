use strict;
use warnings;

package Test::New;
my $CLASS=__PACKAGE__;
our @ISA=qw(Exporter);

#------------------------------------------------------------------

use Exporter;
our @EXPORT_OK=qw(testNewSingleton
                  testNew
                  testNewProperties
                  calcParamsString
                  okErr
                  okProperties
                 );

#------------------------------------------------------------------

use Test::More;
use Test::Builder;

sub okErr(&$$);  #so code earlier in the file will be able to use it

#==================================================================
# FUNCTIONS
#==================================================================

#------------------------------------------------------------------

sub testNewSingleton {
  my ($sContext, $sName, $sClass, $aInput, $aAltInput
     , $hProperties, $hRules) = @_;
  local $Test::Builder::Level = $Test::Builder::Level+1;

  my $sConstructor = 'new';
  if (ref($sClass)eq 'ARRAY') {
    ($sClass, $sConstructor) = @$sClass;
  }
  my $crConstructor = $sClass->can($sConstructor);


  my $oNew = $crConstructor->($sClass, @$aInput);
  my $sNew = "$sContext: $sName(". calcParamString($aInput) . ')';
  ok($oNew, "$sNew created") or undef;

  # verify singleton

  is($crConstructor->($sClass, @$aInput), $oNew
       , "$sContext: $sNew is a singleton");

  # verify properties

  okProperties($oNew, $sNew, $hProperties, $hRules);

  # verify equivalent construction parameters produce same
  # singleton

  foreach my $aParams (@$aAltInput) {
    my $sParams = calcParamString($aParams);
    my $oGot = $crConstructor->($sClass, @$aParams);
    is($oGot, $oNew
       , "$sContext: $sClass->new($sParams) creates same $sName")
      or do {
        if ( $oNew && $oNew->can('getId')
             && $oGot && $oGot->can('getId')) {
          diag("got=",$oGot->getId(),"\nexpected=", $oNew->getId());
        }
      };
  }
  return $oNew;
}

#------------------------------------------------------------------

sub testNew {
  my ($sContext, $sName, $sClass, $aaInput
     , $hProperties, $hRules) = @_;
  my $oNew;

  if (ref($hProperties) eq 'HASH') {
    foreach my $aInput (@$aaInput) {
      $oNew = testNewProperties($sContext, $sName, $sClass, $aInput,[]
                                , $hProperties, $hRules);
    }
  } else {
    my $sErrClass = $hProperties;
    foreach my $aInput (@$aaInput) {
      my $sTest = "$sContext: $sName(".calcParamString($aInput). ')';
      okErr { $sClass->new(@$aInput) } $sTest, $sErrClass;
    }
  }
  return $oNew;
}

#------------------------------------------------------------------

sub testNewProperties {
  my ($sContext, $sName, $sClass, $aInput, $aAltInput
      , $hProperties, $hRules) = @_;
  local $Test::Builder::Level = $Test::Builder::Level+1;

  $sName=$sClass unless defined($sName);

  my $sConstructor = 'new';
  if (ref($sClass)eq 'ARRAY') {
    ($sClass, $sConstructor) = @$sClass;
  }
  my $crConstructor = $sClass->can($sConstructor);

  my $oNew = $crConstructor->($sClass, @$aInput);
  my $sNew = "$sContext: $sName(". calcParamString($aInput) . ')';

  # verify has correct property values

  ok($oNew, "$sNew created") or return undef;
  okProperties($oNew, $sNew, $hProperties, $hRules);

  # verify equivalent construction parameters

  foreach my $aParams (@$aAltInput) {
    my $sAlt = "$sContext: $sName(" .calcParamString($aParams).')';

    # go to next if we can't create this
    my $oAlt = $crConstructor->($sClass, @$aParams);
    ok($oNew, "$sAlt created") or next;
    okProperties($oAlt, $sAlt, $hProperties, $hRules);
  }
  return $oNew;
}

#==================================================================
# HELPER ROUTINES
#==================================================================

#------------------------------------------------------------------

sub calcParamString {
  my ($aParams) = @_;
  return join(',', map { defined($_)?$_:'undef' } @$aParams);
}

#------------------------------------------------------------------

sub okErr(&$$) {
  my ($cr,$sTest,$sExceptionClass) = @_;
  local $Test::Builder::Level = $Test::Builder::Level+1;
  my $e;

  eval {
    local $Test::Builder::Level = $Test::Builder::Level+1;

    &$cr();
    fail("$sTest - verifying exception class: none thrown");
    return 1;
  } or do {
    $e=$@;
    ok(ref($e) && ref($e)->isa($sExceptionClass)
       , "$sTest - verifying exception class")
      or do { diag("Unexpected exception: <$e>");  $e=undef; };
  };
  return $e;
}

#------------------------------------------------------------------

sub okProperties {
  my ($oNew, $sNew, $hProperties, $xRule) = @_;
  local $Test::Builder::Level = $Test::Builder::Level+1;
  return 1 if !defined($hProperties);

  my ($hRules, $aRequired);
  if (ref($xRule) eq 'ARRAY') {
    $aRequired = $xRule;
  } elsif (defined($xRule)) {
    $aRequired = [ keys %$xRule ];
    $hRules = $xRule;
  }

  if (defined($hRules) && ! require Data::Assert) {
    BAIL_OUT("Data::Assert module is required to run this testsuite "
             . "but it cannot be loaded.");
  }

  # verify all required tests have been defined

  if (defined($aRequired)) {
    my $hRequired= {map { $_=>1} @$aRequired};
    my @aMissing = grep { !exists($hRequired->{$_}) } @$aRequired;
    if (scalar @aMissing) {
      diag("Warning: $sNew: expectations missing for: @aMissing");
    }
  }

  while (my ($k,$v) = each(%$hProperties)) {

    my $crProperty = $oNew->can($k);
    if (!defined($crProperty)) {
      diag("Warning! $sNew: possible bad property method name <$k>");
      next;
    }

    if (defined($hRules)) {
      my $oRule= $hRules->{$k};
      ok(Data::Assert::isok("$sNew->$k()", $oNew->$crProperty()
                            , $v, $oRule));
    } else {
      is_deeply($oNew->$crProperty(), $v, "$sNew->$k()");
    }
  }
  return 1;
}

#====================================================================
# MODULE INITIALIZATION
#====================================================================

1;

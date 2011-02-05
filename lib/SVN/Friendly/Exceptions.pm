use strict;
use warnings;

package SVN::Friendly::Exceptions;

#------------------------------------------------------------------
use Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK=qw(makeErrorHandler);

#------------------------------------------------------------------

use Exception::Lite qw(declareExceptionClass);

#------------------------------------------------------------------

sub ERR_BAD_ARG { 'SVN::Friendly::Exception::BadArg' };
declareExceptionClass(ERR_BAD_ARG
  , ['Illegal argument <%s>: %s', qw(arg reason)]);

sub ERR_UNDEF_ARG { 'SVN::Friendly::Exception::UndefArg' };
declareExceptionClass(ERR_UNDEF_ARG
  , ['Illegal argument: missing/undefined value for the %s parameter'
     . ' are not allowd', qw(param)]);

sub ERR_NO_LOG_MSG { 'SVN::Friendly::Exception::NoLogMsg' };
declareExceptionClass(ERR_NO_LOG_MSG
  , ['The current operation tried to change the repository but '
     . 'No log message was provided via the method call']);

sub ERR_SWIG {'SVN::Friendly::Exception::SWIG' };
declareExceptionClass(ERR_SWIG);
# std parameters:
#   errno = SWIG error id

##--------------------------------------------------------------------

#{
#  package SVN::Friendly::ErrString;

#  my $IDX_ID = 0;
#  my $IDX_MSG = 1;

#  sub new() {
#    my $sClass = shift @_;
#    return bless([ @_ ], $sClass);
#  }

#  sub getErrId() { return shift->[$IDX_ID]; }
#  sub getErrMsg() { return shift->[$IDX_MSG]; }
#}

#==================================================================
# FUNCTIONS
#==================================================================

sub makeErrorHandler {
  my ($crCustom) = @_;

  my $crGlobal = $SVN::Error::handler;

  return sub {
    #before Perl 5.0, $[ could be set globally
    #since the original file did not enforce a version limit and
    #we want backwards compatibility with Alien::SVN and friends
    #but we don't want to use the evil $[, we localize it to 0.
    #(as suggested by MidLifeXis (PerlMonk) and confirmed OK in
    #Perl 4 by tye
    #print STDERR "in croak_on_error: verifying\n";

    #Note: don't want to use shift or copy because then we would
    #need to free it to avoid a memory leak.
    local $[ = 0;
    return @_ unless SVN::Error::is_error($_[0]);

    my $oSwigErr = shift;
    my $bDone = 0;
    if ($crCustom) {
      my $bDiscard = 0;

      eval {
        #discard error or pass through
        $bDiscard = &$crCustom($oSwigErr);
        return 1;
      } or do {
        #in case error is thrown
        my $oErr=$@;
        $oSwigErr->clear();
        die $oErr;
      };

      if ($bDiscard) {
        $oSwigErr->clear();
        return;
      }
    }

    &$crGlobal($oSwigErr) if $crGlobal;
  };
}

#code based on SVN::Core::croak_on_error
#with three modifications:
# 1) $[ localized so 0 can be used as base
# 2) A ref to a pure perl error object rather than a string is thrown
# 3) Stack tracing of Exception::Lite is used rather than carp

sub croak_on_error {
  #before Perl 5.0, $[ could be set globally
  #since the original file did not enforce a version limit and
  #we want backwards compatibility with Alien::SVN and friends
  #but we don't want to use the evil $[, we localize it to 0.
  #(as suggested by MidLifeXis (PerlMonk) and confirmed OK in
  #Perl 4 by tye
  #print STDERR "in croak_on_error: verifying\n";


  #Note: don't want to use shift or copy because then we would
  #need to free it to avoid a memory leak.
  local $[ = 0;
  return @_ unless SVN::Error::is_error($_[0]);

  #print STDERR "in croak_on_error: processing\n";

  my $oSwigErr = shift;
  my $oPerlErr = ERR_SWIG->new($oSwigErr->expanded_message()
                               , errno => $oSwigErr->apr_err());
  #my $oPerlErr = SVN::Friendly::ErrString->new
  #  ($oSwigErr->apr_err(), $oSwigErr->expanded_message());


  #gotta free the memory - to prevent a leak
  $oSwigErr->clear();

  #croak($oPerlErr);
  die $oPerlErr;
}

sub confess_on_error {
  #before Perl 5.0, $[ could be set globally
  #since the original file did not enforce a version limit and
  #we want backwards compatibility with Alien::SVN and friends
  #but we don't want to use the evil $[, we localize it to 0.
  #(as suggested by MidLifeXis (PerlMonk) and confirmed OK in
  #Perl 4 by tye
  #print STDERR "in croak_on_error: verifying\n";


  #Note: don't want to use shift or copy because then we would
  #need to free it to avoid a memory leak.
  local $[ = 0;
  return @_ unless SVN::Error::is_error($_[0]);

  #print STDERR "in croak_on_error: processing\n";

  my $oSwigErr = shift;
  my $oPerlErr = ERR_SWIG->new($oSwigErr->expanded_message()
                               , errno => $oSwigErr->apr_err());
  #my $oPerlErr = SVN::Friendly::ErrString->new
  #  ($oSwigErr->apr_err(), $oSwigErr->expanded_message());


  #gotta free the memory - to prevent a leak
  $oSwigErr->clear();

  #confess($oPerlErr);
  print STDERR "$oPerlErr";
}

#==================================================================
# MODULE INITIALIZATION
#==================================================================

1;

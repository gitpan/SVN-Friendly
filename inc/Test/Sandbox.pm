use strict;
use warnings;

package Test::Sandbox;
my $CLASS=__PACKAGE__;
our @ISA=qw(Exporter);

#--------------------------------------------------------------------

use Exporter;
our @EXPORT_OK=qw(makeSandbox addDir addFile addPaths);

#--------------------------------------------------------------------

#use Test::More;
#use Test::Builder;

#--------------------------------------------------------------------

use File::Spec ();
use File::Temp ();
use File::Find ();

my @TEMP_CHARS = ( 0..9, 'A'..'Z', 'a'..'z' );

#--------------------------------------------------------------------

#====================================================================
# CLASS METHODS
#====================================================================

sub new {
  my ($sClass, $sForClass, $sRoot) = @_;

  $sRoot = File::Spec->tmpdir()  unless defined($sRoot);

  my $sSandboxRoot;
  if (defined($sForClass)) {
    my $sRelPath = $sForClass;  $sRelPath =~ s/::/_/g;
    $sSandboxRoot = File::Spec->rel2abs($sRelPath, $sRoot);
  } else {
    $sSandboxRoot = $sRoot;
  }

  mkdir $sSandboxRoot;
  my $sSandbox = File::Temp::tempdir( DIR => $sSandboxRoot
                                      , CLEANUP => 1 );
  return bless(\$sSandbox, $sClass);
}

#--------------------------------------------------------------------

sub newForRelpath {
  my ($sClass, $sRoot, $sRelPath) = @_;
  my $sFullName = _makeFullName($sRoot, $sRelPath);
  return $sClass->new(undef, $sFullName);
}

#--------------------------------------------------------------------

sub makeSandbox {
  return __PACKAGE__->new(@_)->getRoot();
}

#====================================================================
# OBJECT METHODS
#====================================================================

#--------------------------------------------------------------------

sub addDir {
  my $sSandbox = _shiftSandbox(\@_);
  my ($sRelPath, $bTemp) = @_;
  $bTemp = (defined($sRelPath)?0:1) unless defined($bTemp);
  my $sFullPath = _makeFullName($sSandbox, $sRelPath);

  if ($bTemp) {
    my $sTemp = File::Temp::tempdir( DIR => $sFullPath, CLEANUP => 1 )
      or die "Can't make temp directory in <$sFullPath>: $!";
    return $sTemp;
  } else {
    mkdir($sFullPath) or die "Can't make directory <$sFullPath>: $!";
    return $sFullPath;
  }
}

#--------------------------------------------------------------------

sub addFile {
  my $sSandbox = _shiftSandbox(\@_);
  my ($sRelPath, $sContent) = @_;
  my $sFullPath = defined($sRelPath)
    ? _makeFullName($sSandbox, $sRelPath,1)
    : File::Temp->new(DIR => $sSandbox, UNLINK => 1)->filename();

  open(my $fh, '>', $sFullPath)
    or die("Can't open <$sFullPath> for writing: $!");
  if (defined($sContent) && length($sContent)) {
    print $fh $sContent;
  }
  close $fh;
  return $sFullPath;
}

#--------------------------------------------------------------------
# adds a file in ini format used by many apps to configure themselves

sub addIniFile {
  my ($xSandbox, $sRelPath, $hProps) = @_;

  my $sProps='';
  while (my ($sSection,$hOptions) = each(%$hProps)) {
    $sProps .= "[$sSection]\n";
    while (my ($k,$v) = each (%$hOptions)) {
      $sProps .= "$k = $v\n";
    }
    $sProps .= "\n";
  }
  return addFile($xSandbox, $sRelPath, $sProps);
}

#--------------------------------------------------------------------

sub addPaths {
  # $sPathInSandbox  a sandbox created by makeSandbox() or ->new()
  # $xFiles    array reference containing the names of files and
  #            directories that should be prepopulated
  #            -or-
  #            hash reference whose keys are files and directories
  #            and whose values, if present, are the content of
  #            files.
  my $sSandbox = _shiftSandbox(\@_);
  my ($sDirPath, $xPaths) = @_;
  if (ref($sDirPath)) {
    $xPaths = $sDirPath;
    $sDirPath = undef;
  }

  my (@aPaths, $hPaths, $hFullPaths);
  if (ref($xPaths) eq 'ARRAY') {
    @aPaths = sort @$xPaths;
  } else {
    $hPaths = $xPaths;
    @aPaths = sort keys %$hPaths;
  }

  foreach my $sRelPath (@aPaths) {
    my $sDirRelPath = defined($sDirPath)
      ? "$sDirPath/$sRelPath" : $sRelPath;

    my $sFullPath = $sRelPath =~ m{/$}
      ? addDir($sSandbox, $sDirRelPath)
      : addFile($sSandbox, $sDirRelPath, $hPaths->{$sRelPath});
    $hFullPaths->{$sRelPath} = $sFullPath;
  }
  return $hFullPaths;
}

#--------------------------------------------------------------------

sub appendToFile {
  my $sSandbox = _shiftSandbox(\@_);
  my ($sRelPath, $sContent) = @_;
  my $sFullPath = _makeFullName($sSandbox, $sRelPath,1);

  open(my $fh, '>>', $sFullPath)
    or die("Can't open <$sFullPath> for writing: $!");
  if (defined($sContent) && length($sContent)) {
    print $fh $sContent;
  }
  close $fh;
  return $sFullPath;
}

#--------------------------------------------------------------------

sub createReadWriteStream {
  my $sSandbox = _shiftSandbox(\@_);
  return File::Temp->new(DIR => $sSandbox, UNLINK => 1);
}

#--------------------------------------------------------------------

sub getContent {
  my $sSandbox = _shiftSandbox(\@_);
  my ($sRelPath) = @_;
  my $sFullPath = _makeFullName($sSandbox, $sRelPath,1);

  open(my $fh, '<', $sFullPath);
  local $/;
  my $sContent = <$fh>;
  return $sContent;
}

#--------------------------------------------------------------------

sub getRoot { return ref($_[0]) ? ${$_[0]} : $_[0]; }

#--------------------------------------------------------------------

sub getFullPathName {
  my $sSandbox = _shiftSandbox(\@_);
  my ($sRelPath, $bFile) = @_;
  return _makeFullName($sSandbox, $sRelPath, $bFile);
}

#--------------------------------------------------------------------

sub getNonExistantPathName {
  my $sSandbox = _shiftSandbox(\@_);
  my ($bFile, $sTemplate, $sSuffix) = @_;
  return _makeTempName($sSandbox, $bFile, $sTemplate, $sSuffix);
}

#--------------------------------------------------------------------

sub list {
  my $sSandbox = _shiftSandbox(\@_);
  my ($sRelPath, $bRecurse) = @_;
  my $sFullPath = _makeFullName($sSandbox, $sRelPath,0);

  my @aMembers;

  my @aPath;
  my $crVisit = sub {
    my $sRelPath;

    if (-d) {
      push @aPath, $_;

      # don't add current directory to members
      # don't prune either - File::Find puts './' before files but
      # not directories in the current directory.

      return if ($_ eq File::Spec->curdir());

      $sRelPath = File::Spec->catdir(@aPath[1..$#aPath]);
      $File::Find::prune=1 unless $bRecurse;
    } elsif (scalar(@aPath) == 1) {
      $sRelPath = $_;
    } else {
      $sRelPath = File::Spec->catfile(@aPath[1..$#aPath], $_);
    }
    push @aMembers, $sRelPath;
  };

  my $crPost = sub { pop @aPath; };

  File::Find::find({ wanted => $crVisit, postprocess => $crPost }
                   , $sFullPath);
  return \@aMembers;
}

#--------------------------------------------------------------------

sub makeChild {
  my $sSandbox = _shiftSandbox(\@_);
  my ($sRelPath) = @_;
  my $sFullPath;

  if (!defined($sRelPath)) {
    $sFullPath = addDir($sSandbox);
  } elsif (File::Spec->file_name_is_absolute($sRelPath)) {
    die("Illegal argument to getChildSandbox, arg 1 "
        ."must be a relative path");
  } else {
    $sFullPath = _makeFullName($sSandbox, $sRelPath,1);
    mkdir $sFullPath unless -d $sFullPath;
  }

  return bless(\$sFullPath, __PACKAGE__);
}


#--------------------------------------------------------------------

sub removePath {
  my $sSandbox = _shiftSandbox(\@_);
  my ($sRelPath) = @_;
  my $sFullPath = _makeFullName($sSandbox, $sRelPath,1);

  if (-d $sFullPath) {
    rmdir $sFullPath;
  } else {
    unlink $sFullPath;
  }
}

#--------------------------------------------------------------------

sub renamePath {
  my $sSandbox = _shiftSandbox(\@_);
  my ($sRelPathFrom, $sRelPathTo) = @_;
  my $sFrom = _makeFullName($sSandbox, $sRelPathFrom,1);
  my $sTo = _makeFullName($sSandbox, $sRelPathTo,1);

  rename $sFrom, $sTo;
}

#====================================================================
# FUNCTIONS
#====================================================================

#--------------------------------------------------------------------

sub _appendRelPaths {
  my ($sDir, $aRelPaths) = @_;
  return defined($aRelPaths)
    ? [ map { "$sDir/$_" } @$aRelPaths ] : [];
}

#--------------------------------------------------------------------

sub _makeFullName {
  my ($sSandbox, $sRelPath, $bFile) = @_;
  if (!defined($sRelPath) || !length($sRelPath)) {
    return $sSandbox;
  } elsif (File::Spec->file_name_is_absolute($sRelPath)) {
    return $sRelPath;
  } else {
    my @aComponents = split('/', $sRelPath);
    my $sNative = $bFile
      ? File::Spec->catfile(@aComponents)
      : File::Spec->catdir(@aComponents);
    return File::Spec->rel2abs( $sNative, $sSandbox);
  }
}

#--------------------------------------------------------------------

sub _makeTempName {
  my ($self, $sSandbox, $bFile, $sTemplate, $sSuffix) = @_;
  $sTemplate = 'tempXXXX' unless defined($sTemplate);

  while (1) {

    # generate POSIX syntax temp file/dir name
    my @aTemplate = split('',$sTemplate);
    foreach my $ch (@aTemplate) {
      if ($ch eq 'X') {
        $ch = $TEMP_CHARS[int rand(scalar @TEMP_CHARS)];
      }
    }
    my $sRelPath = join('',@aTemplate);
    $sRelPath .= $sSuffix if defined($sSuffix);
    my $sFullPath = _makeFullName($sSandbox, $sRelPath, $bFile);
    return $sFullPath unless (-e $sFullPath);
  }
  return undef;
}

#--------------------------------------------------------------------

sub _shiftSandbox {
  my $aArgs = $_[0];
  return ref($aArgs->[0])? ${shift @$aArgs} : shift @$aArgs;
}

#====================================================================
# MODULE INITIALIZATION
#====================================================================

1;

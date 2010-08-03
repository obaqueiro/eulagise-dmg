#!/usr/bin/perl

# eulagise.pl
# Pete Goodliffe

# Added a EULA to a pre-existing DMG disk image.

# Based on a more fully-featured script found here:
#     http://mxr.mozilla.org/seamonkey/source/build/package/mac_osx/pkg-dmg?raw=1
# This script focuses only on adding a EULA to a DMG.

use strict;
use warnings;

use Fcntl;
use POSIX;
use Getopt::Long;

sub argumentEscape(@);
sub cleanupDie($);
sub command(@);
sub commandInternal($@);
sub commandInternalVerbosity($$@);
sub commandOutput(@);
sub commandOutputVerbosity($@);
sub commandVerbosity($@);
sub licenseMaker($$);
sub pathSplit($);


# Variables used as globals
my(@gCleanup, %gConfig, $gDarwinMajor, $gDryRun, $gVerbosity);

# Use the commands by name if they're expected to be in the user's
# $PATH (/bin:/sbin:/usr/bin:/usr/sbin).  Otherwise, go by absolute
# path.  These may be overridden with --config.
%gConfig = ('cmd_bless'          => 'bless',
            'cmd_chmod'          => 'chmod',
            'cmd_diskutil'       => 'diskutil',
            'cmd_du'             => 'du',
            'cmd_hdid'           => 'hdid',
            'cmd_hdiutil'        => 'hdiutil',
            'cmd_mkdir'          => 'mkdir',
            'cmd_mktemp'         => 'mktemp',
            'cmd_Rez'            => '/Developer/Tools/Rez',
            'cmd_rm'             => 'rm',
            'cmd_rsync'          => 'rsync',
            'cmd_SetFile'        => '/Developer/Tools/SetFile',

            # create_directly indicates whether hdiutil create supports
            # -srcfolder and -srcdevice.  It does on >= 10.3 (Panther).
            # This is fixed up for earlier systems below.  If false,
            # hdiutil create is used to create empty disk images that
            # are manually filled.
            'create_directly'    => 1,

            # If hdiutil attach -mountpoint exists, use it to avoid
            # mounting disk images in the default /Volumes.  This reduces
            # the likelihood that someone will notice a mounted image and
            # interfere with it.  Only available on >= 10.3 (Panther),
            # fixed up for earlier systems below.
            #
            # This is presently turned off for all systems, because there
            # is an infrequent synchronization problem during ejection.
            # diskutil eject might return before the image is actually
            # unmounted.  If pkg-dmg then attempts to clean up its
            # temporary directory, it could remove items from a read-write
            # disk image or attempt to remove items from a read-only disk
            # image (or a read-only item from a read-write image) and fail,
            # causing pkg-dmg to abort.  This problem is experienced
            # under Tiger, which appears to eject asynchronously where
            # previous systems treated it as a synchronous operation.
            # Using hdiutil attach -mountpoint didn't always keep images
            # from showing up on the desktop anyway.
            'hdiutil_mountpoint' => 0,

            # hdiutil makehybrid results in optimized disk images that
            # consume less space and mount more quickly.  Use it when
            # it's available, but that's only on >= 10.3 (Panther).
            # If false, hdiutil create is used instead.  Fixed up for
            # earlier systems below.
            'makehybrid'         => 1,

            # hdiutil create doesn't allow specifying a folder to open
            # at volume mount time, so those images are mounted and
            # their root folders made holy with bless -openfolder.  But
            # only on >= 10.3 (Panther).  Earlier systems are out of luck.
            # Even on Panther, bless refuses to run unless root.
            # Fixed up below.
            'openfolder_bless'   => 1,

            # It's possible to save a few more kilobytes by including the
            # partition only without any partition table in the image.
            # This is a good idea on any system, so turn this option off.
            #
            # Except it's buggy.  "-layout NONE" seems to be creating
            # disk images with more data than just the partition table
            # stripped out.  You might wind up losing the end of the
            # filesystem - the last file (or several) might be incomplete.
            'partition_table'    => 1,

            # To create a partition table-less image from something
            # created by makehybrid, the hybrid image needs to be
            # mounted and a new image made from the device associated
            # with the relevant partition.  This requires >= 10.4
            # (Tiger), presumably because earlier systems have
            # problems creating images from devices themselves attached
            # to images.  If this is false, makehybrid images will
            # have partition tables, regardless of the partition_table
            # setting.  Fixed up for earlier systems below.
            'recursive_access'   => 1);

# --verbosity
$gVerbosity = 2;

# --dry-run
$gDryRun = 0;

# %gConfig fix-ups based on features and bugs present in certain releases.
my($ignore, $uname_r, $uname_s);
($uname_s, $ignore, $uname_r, $ignore, $ignore) = POSIX::uname();
if($uname_s eq 'Darwin') {
  ($gDarwinMajor, $ignore) = split(/\./, $uname_r, 2);

  # $major is the Darwin major release, which for our purposes, is 4 higher
  # than the interesting digit in a Mac OS X release.
  if($gDarwinMajor <= 6) {
    # <= 10.2 (Jaguar)
    # hdiutil create does not support -srcfolder or -srcdevice
    $gConfig{'create_directly'} = 0;
    # hdiutil attach does not support -mountpoint
    $gConfig{'hdiutil_mountpoint'} = 0;
    # hdiutil mkhybrid does not exist
    $gConfig{'makehybrid'} = 0;
  }
  if($gDarwinMajor <= 7) {
    # <= 10.3 (Panther)
    # Can't mount a disk image and then make a disk image from the device
    $gConfig{'recursive_access'} = 0;
    # bless does not support -openfolder on 10.2 (Jaguar) and must run
    # as root under 10.3 (Panther)
    $gConfig{'openfolder_bless'} = 0;
  }
}
else {
  # If it's not Mac OS X, just assume all of those good features are
  # available.  They're not, but things will fail long before they
  # have a chance to make a difference.
  #
  # Now, if someone wanted to document some of these private formats...
  print STDERR ($0.": warning, not running on Mac OS X, ".
   "this could be interesting.\n");
}

# Non-global variables used in Getopt
my(@attributes, @copyFiles, @createSymlinks, $iconFile, $idme, $licenseFile,
 @makeDirs, $outputFormat, @resourceFiles, $sourceFile, $sourceFolder,
 $targetImage, $tempDir, $volumeName);

# --format
$outputFormat = 'UDZO';

# --idme
$idme = 0;

# --sourcefile
$sourceFile = 0;

# Leaving this might screw up the Apple tools.
delete $ENV{'NEXT_ROOT'};

# This script can get pretty messy, so trap a few signals.
$SIG{'INT'} = \&trapSignal;
$SIG{'HUP'} = \&trapSignal;
$SIG{'TERM'} = \&trapSignal;

# PETE: shortened
Getopt::Long::Configure('pass_through');
GetOptions(
           'target=s'    => \$targetImage,
           'license=s'   => \$licenseFile,
           'config=s'    => \%gConfig); # "hidden" option not in usage()

# PETE: added
if(!defined($licenseFile) || !defined($targetImage)) {
  # it's required
  print STDERR "No licence file, or input, or output\n";
  exit(1);
}

my(@tempDirComponents, $targetImageFilename);
@tempDirComponents = pathSplit($targetImage);
$targetImageFilename = pop(@tempDirComponents);

if(defined($tempDir)) {
  @tempDirComponents = pathSplit($tempDir);
}
else {
  # Default tempDir is the same directory as what is specified for
  # targetImage
  $tempDir = join('/', @tempDirComponents);
}

# Make a temporary directory in $tempDir for our own nefarious purposes.
my(@output, $tempSubdir, $tempSubdirTemplate);
$tempSubdirTemplate=join('/', @tempDirComponents,
 'pkg-dmg.'.$$.'.XXXXXXXX');
if(!(@output = commandOutput($gConfig{'cmd_mktemp'}, '-d',
 $tempSubdirTemplate)) || $#output != 0) {
  cleanupDie('mktemp failed');
}

if($gDryRun) {
  (@output)=($tempSubdirTemplate);
}

($tempSubdir) = @output;

push(@gCleanup,
 sub {commandVerbosity(0, $gConfig{'cmd_rm'}, '-rf', $tempSubdir);});

# PETE: removed mount point code

my($unflattenable);
#if(isFormatCompressed($outputFormat)) {
  $unflattenable = 1;
#}
#else {
#  $unflattenable = 0;
#}

if(defined($licenseFile) && $licenseFile ne '') {
  my($licenseResource);
  $licenseResource = $tempSubdir.'/license.r';
  if(!licenseMaker($licenseFile, $licenseResource)) {
    cleanupDie('licenseMaker failed');
  }
  push(@resourceFiles, $licenseResource);
  # Don't add a cleanup object because licenseResource is in tempSubdir.
}

if(@resourceFiles) {
  # Add resources, such as a license agreement.

  # Only unflatten read-only and compressed images.  It's not supported
  # on other image times.
  if($unflattenable &&
   (command($gConfig{'cmd_hdiutil'}, 'unflatten', $targetImage)) != 0) {
    cleanupDie('hdiutil unflatten failed');
  }
  # Don't push flatten onto the cleanup stack.  If we fail now, we'll be
  # removing $targetImage anyway.

  # Type definitions come from Carbon.r.
  if(command($gConfig{'cmd_Rez'}, 'Carbon.r', @resourceFiles, '-a', '-o',
   $targetImage) != 0) {
    cleanupDie('Rez failed');
  }

  # Flatten.  This merges the resource fork into the data fork, so no
  # special encoding is needed to transfer the file.
  if($unflattenable &&
   (command($gConfig{'cmd_hdiutil'}, 'flatten', $targetImage)) != 0) {
    cleanupDie('hdiutil flatten failed');
  }
}

# No need to remove licenseResource separately, it's in tempSubdir.
if(command($gConfig{'cmd_rm'}, '-rf', $tempSubdir) != 0) {
  cleanupDie('rm -rf tempSubdir failed');
}

if($idme) {
  if(command($gConfig{'cmd_hdiutil'}, 'internet-enable', '-yes',
   $targetImage) != 0) {
    cleanupDie('hdiutil internet-enable failed');
  }
}

# Done.

exit(0);

#==============================================================================

# argumentEscape(@arguments)
#
# Takes a list of @arguments and makes them shell-safe.
sub argumentEscape(@) {
  my(@arguments);
  @arguments = @_;
  my($argument, @argumentsOut);
  foreach $argument (@arguments) {
    $argument =~ s%([^A-Za-z0-9_\-/.=+,])%\\$1%g;
    push(@argumentsOut, $argument);
  }
  return @argumentsOut;
}

# cleanupDie($message)
#
# Displays $message as an error message, and then runs through the
# @gCleanup stack, performing any cleanup operations needed before
# exiting.  Does not return, exits with exit status 1.
sub cleanupDie($) {
  my($message);
  ($message) = @_;
  print STDERR ($0.': '.$message.(@gCleanup?' (cleaning up)':'')."\n");
  while(@gCleanup) {
    my($subroutine);
    $subroutine = pop(@gCleanup);
    &$subroutine;
  }
  exit(1);
}
# command(@arguments)
#
# Runs the specified command at the verbosity level defined by $gVerbosity.
# Returns nonzero on failure, returning the exit status if appropriate.
# Discards command output.
sub command(@) {
  my(@arguments);
  @arguments = @_;
  return commandVerbosity($gVerbosity,@arguments);
}

# commandInternal($command, @arguments)
#
# Runs the specified internal command at the verbosity level defined by
# $gVerbosity.
# Returns zero(!) on failure, because commandInternal is supposed to be a
# direct replacement for the Perl system call wrappers, which, unlike shell
# commands and C equivalent system calls, return true (instead of 0) to
# indicate success.
sub commandInternal($@) {
  my(@arguments, $command);
  ($command, @arguments) = @_;
  return commandInternalVerbosity($gVerbosity, $command, @arguments);
}

# commandInternalVerbosity($verbosity, $command, @arguments)
#
# Run an internal command, printing a bogus command invocation message if
# $verbosity is true.
#
# If $command is unlink:
# Removes the files specified by @arguments.  Wraps unlink.
#
# If $command is symlink:
# Creates the symlink specified by @arguments. Wraps symlink.
sub commandInternalVerbosity($$@) {
  my(@arguments, $command, $verbosity);
  ($verbosity, $command, @arguments) = @_;
  if($command eq 'unlink') {
    if($verbosity || $gDryRun) {
      print(join(' ', 'rm', '-f', argumentEscape(@arguments))."\n");
    }
    if($gDryRun) {
      return $#arguments+1;
    }
    return unlink(@arguments);
  }
  elsif($command eq 'symlink') {
    if($verbosity || $gDryRun) {
      print(join(' ', 'ln', '-s', argumentEscape(@arguments))."\n");
    }
    if($gDryRun) {
      return 1;
    }
    my($source, $target);
    ($source, $target) = @arguments;
    return symlink($source, $target);
  }
}

# commandOutput(@arguments)
#
# Runs the specified command at the verbosity level defined by $gVerbosity.
# Output is returned in an array of lines.  undef is returned on failure.
# The exit status is available in $?.
sub commandOutput(@) {
  my(@arguments);
  @arguments = @_;
  return commandOutputVerbosity($gVerbosity, @arguments);
}

# commandOutputVerbosity($verbosity, @arguments)
#
# Runs the specified command at the verbosity level defined by the
# $verbosity argument.  Output is returned in an array of lines.  undef is
# returned on failure.  The exit status is available in $?.
#
# If an error occurs in fork or exec, an error message is printed to
# stderr and undef is returned.
#
# If $verbosity is 0, the command invocation is not printed, and its
# stdout is not echoed back to stdout.
#
# If $verbosity is 1, the command invocation is printed.
#
# If $verbosity is 2, the command invocation is printed and the output
# from stdout is echoed back to stdout.
#
# Regardless of $verbosity, stderr is left connected.
sub commandOutputVerbosity($@) {
  my(@arguments, $verbosity);
  ($verbosity, @arguments) = @_;
  my($pid);
  if($verbosity || $gDryRun) {
    print(join(' ', argumentEscape(@arguments))."\n");
  }
  if($gDryRun) {
    return(1);
  }
  if (!defined($pid = open(*COMMAND, '-|'))) {
    printf STDERR ($0.': fork: '.$!."\n");
    return undef;
  }
  elsif ($pid) {
    # parent
    my(@lines);
    while(!eof(*COMMAND)) {
      my($line);
      chop($line = <COMMAND>);
      if($verbosity > 1) {
        print($line."\n");
      }
      push(@lines, $line);
    }
    close(*COMMAND);
    if ($? == -1) {
      printf STDERR ($0.': fork: '.$!."\n");
      return undef;
    }
    elsif ($? & 127) {
      printf STDERR ($0.': exited on signal '.($? & 127).
       ($? & 128 ? ', core dumped' : '')."\n");
      return undef;
    }
    return @lines;
  }
  else {
    # child; this form of exec is immune to shell games
    if(!exec {$arguments[0]} (@arguments)) {
      printf STDERR ($0.': exec: '.$!."\n");
      exit(-1);
    }
  }
}

# commandVerbosity($verbosity, @arguments)
#
# Runs the specified command at the verbosity level defined by the
# $verbosity argument.  Returns nonzero on failure, returning the exit
# status if appropriate.  Discards command output.
sub commandVerbosity($@) {
  my(@arguments, $verbosity);
  ($verbosity, @arguments) = @_;
  if(!defined(commandOutputVerbosity($verbosity, @arguments))) {
    return -1;
  }
  return $?;
}

# licenseMaker($text, $resource)
#
# Takes a plain text file at path $text and creates a license agreement
# resource containing the text at path $license.  English-only, and
# no special formatting.  This is the bare-bones stuff.  For more
# intricate license agreements, create your own resource.
#
# ftp://ftp.apple.com/developer/Development_Kits/SLAs_for_UDIFs_1.0.dmg
sub licenseMaker($$) {
  my($resource, $text);
  ($text, $resource) = @_;
  if(!sysopen(*TEXT, $text, O_RDONLY)) {
    print STDERR ($0.': licenseMaker: sysopen text: '.$!."\n");
    return 0;
  }
  if(!sysopen(*RESOURCE, $resource, O_WRONLY|O_CREAT|O_EXCL)) {
    print STDERR ($0.': licenseMaker: sysopen resource: '.$!."\n");
    return 0;
  }
  print RESOURCE << '__EOT__';
// See /System/Library/Frameworks/CoreServices.framework/Frameworks/CarbonCore.framework/Headers/Script.h for language IDs.
data 'LPic' (5000) {
  // Default language ID, 0 = English
  $"0000"
  // Number of entries in list
  $"0001"

  // Entry 1
  // Language ID, 0 = English
  $"0000"
  // Resource ID, 0 = STR#/TEXT/styl 5000
  $"0000"
  // Multibyte language, 0 = no
  $"0000"
};

resource 'STR#' (5000, "English") {
  {
    // Language (unused?) = English
    "English",
    // Agree
    "Agree",
    // Disagree
    "Disagree",
__EOT__
    # This stuff needs double-quotes for interpolations to work.
    print RESOURCE ("    // Print, ellipsis is 0xC9\n");
    print RESOURCE ("    \"Print\xc9\",\n");
    print RESOURCE ("    // Save As, ellipsis is 0xC9\n");
    print RESOURCE ("    \"Save As\xc9\",\n");
    print RESOURCE ('    // Descriptive text, curly quotes are 0xD2 and 0xD3'.
     "\n");
    print RESOURCE ('    "If you agree to the terms of this license '.
     "agreement, click \xd2Agree\xd3 to access the software.  If you ".
     "do not agree, press \xd2Disagree.\xd3\"\n");
print RESOURCE << '__EOT__';
  };
};

// Beware of 1024(?) byte (character?) line length limitation.  Split up long
// lines.
// If straight quotes are used ("), remember to escape them (\").
// Newline is \n, to leave a blank line, use two of them.
// 0xD2 and 0xD3 are curly double-quotes ("), 0xD4 and 0xD5 are curly
//   single quotes ('), 0xD5 is also the apostrophe.
data 'TEXT' (5000, "English") {
__EOT__

  while(!eof(*TEXT)) {
    my($line);
    chop($line = <TEXT>);

    while(defined($line)) {
      my($chunk);

      # Rez doesn't care for lines longer than (1024?) characters.  Split
      # at less than half of that limit, in case everything needs to be
      # backwhacked.
      if(length($line)>500) {
        $chunk = substr($line, 0, 500);
        $line = substr($line, 500);
      }
      else {
        $chunk = $line;
        $line = undef;
      }

      if(length($chunk) > 0) {
        # Unsafe characters are the double-quote (") and backslash (\), escape
        # them with backslashes.
        $chunk =~ s/(["\\])/\\$1/g;

        print RESOURCE '  "'.$chunk.'"'."\n";
      }
    }
    print RESOURCE '  "\n"'."\n";
  }
  close(*TEXT);

  print RESOURCE << '__EOT__';
};

data 'styl' (5000, "English") {
  // Number of styles following = 1
  $"0001"

  // Style 1.  This is used to display the first two lines in bold text.
  // Start character = 0
  $"0000 0000"
  // Height = 16
  $"0010"
  // Ascent = 12
  $"000C"
  // Font family = 1024 (Lucida Grande)
  $"0400"
  // Style bitfield, 0x1=bold 0x2=italic 0x4=underline 0x8=outline
  // 0x10=shadow 0x20=condensed 0x40=extended
  $"00"
  // Style, unused?
  $"02"
  // Size = 12 point
  $"000C"
  // Color, RGB
  $"0000 0000 0000"
};
__EOT__
  close(*RESOURCE);

  return 1;
}

# pathSplit($pathname)
#
# Splits $pathname into an array of path components.
sub pathSplit($) {
  my($pathname);
  ($pathname) = @_;
  return split(/\//, $pathname);
}


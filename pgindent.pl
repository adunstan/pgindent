#!/bin/env perl

use strict;
use warnings;

use File::Temp;
use IO::Handle;
use File::Find;
use Getopt::Long;
use Cwd qw(abs_path getcwd);

my ($typedefs_file, $code_base, $excludes, $indent,$build);
my %options =(
    "typedefs=s" => \$typedefs_file,
    "code-base=s" => \$code_base,
    "excludes=s" => \$excludes,
    "indent=s" => \$indent,
    "build" => \$build,
);
GetOptions(%options) || die "bad command line";

run_build($code_base)
  if ($build);

# legacy settings and defaults

# try fairly hard to find the typedefs file if it's not set
# command line option wins, then first non-option arg,
# then environment (which is how --build sets it) ,
# then locations. based on current dir, then default location
$typedefs_file  ||= shift unless @ARGV && $ARGV[0] !~ /\\.[ch]$/;
$typedefs_file ||= $ENV{PGTYPEDEFS};
foreach my $try ('.','src/tools/pgindent','/usr/local/etc')
{
    $typedefs_file ||= "$try/typedefs.list"
      if (-f "$try/typedefs.list");
}
my $tdtry = "..";
foreach (1..5)
{
    last if $typedefs_file;
    $typedefs_file ||= "$tdtry/src/tools/pgindent/typedefs.list"
      if (-f "$tdtry/src/tools/pgindent/typedefs.list");
    $tdtry = "$tdtry/..";
}
die "no typedefs file" unless $typedefs_file && -f $typedefs_file;

# build mode sets PGINDENT and PGENTAB
$indent ||= $ENV{PGINDENT} || $ENV{INDENT} || "indent";
my $entab = $ENV{PGENTAB} || "entab";

# no non-option arguments given. so do everything
# under the current directory
$code_base ||= '.'
  unless @ARGV;

# if it's the base of a postgres tree, we will exclude the files
# postgres wants excluded
$excludes ||= "$code_base/src/tools/pgindent/exclude_file_patterns"
  if $code_base && -f "$code_base/src/tools/pgindent/exclude_file_patterns";

my @files;

# get the list of files under code base, if it's set
File::Find::find(
    {
        wanted =>sub{
            my ($dev,$ino,$mode,$nlink,$uid,$gid);
            (($dev,$ino,$mode,$nlink,$uid,$gid) = lstat($_))
              &&-f _
              &&/^.*\.[ch]\z/s
              &&push(@files,$File::Find::name);
          }
    },
    $code_base
)if $code_base;

# exclude files postgres wants excluded, if we know what they are
if ($excludes && @files)
{
    my $eh;
    my @excl;
    open($eh,$excludes) || die "opening $excludes";
    while (my $line = <$eh>)
    {
        chomp $line;
        my $rgx;
        eval " \$rgx = qr!$line!;";
        @files = grep {$_ !~ /$rgx/} @files if $rgx;
    }
    close($eh);
}

# read in and filter the typedefs
my $tdfile;
open($tdfile,$typedefs_file) || die "opening $typedefs_file: $!";
my @typedefs = <$tdfile>;
close($tdfile);
chomp @typedefs;
@typedefs = grep {!/^(FD_SET|date|interval|timestamp|ANY)$/ } @typedefs;

# Common indent settings
my $indent_opts ="-bad -bap -bc -bl -d0 -cdb -nce -nfc1 -di12 -i4 -l79 -lp -nip -npro -bbb";

# indent-dependant settings
my $extra_opts = "";

# make sure we have working indent and entab

system('$entab </dev/null >/dev/null');
if ($?)
{
    print  STDERR
      "Go to the src/tools/entab directory and do 'make' and 'make install'.\n",
      "This will put the 'entab' command in your path.\n",
      "Then run $0 again.\n";
    exit 1;
}
system("$indent -? </dev/null >/dev/null 2>&1");
if ( $? >>8  != 1 )
{
    print STDERR"You do not appear to have 'indent' installed on your system.\n";
    exit 1;
}

system("$indent -gnu </dev/null >/dev/null 2>&1");
if ( $? == 0 )
{
    print STDERR
      "You appear to have GNU indent rather than BSD indent.\n",
      "See the pgindent/README file for a description of its problems.\n";
    $extra_opts = "-cdb -bli0 -npcs -cli4 -sc";
}
else
{
    $extra_opts = "-cli1";
}

# make sure we process any non-option arguments.
push(@files,@ARGV);

#print "indent: $indent, entab: $entab\nfiles:",scalar(@files),"\n";
#printf "code_base: %s\n", (defined($code_base) ? $code_base : '.');

# run the indent
foreach my $sourcefile (@files)
{
    indent_file($sourcefile,\@typedefs);
}

# cleanup from build
build_clean($code_base)
  if $build;

exit;

#########################################################
# subroutines

sub indent_file
{
    my $sourcename = shift;
    my $typedefs = shift;

    # print STDERR "indenting $sourcename\n";

    my $source = read_source($sourcename);

    # for use in dev diagnostics
    my $bsource = $source;

    # Convert // comments to /* */
    $source =~ s!^(\h*)//(.*)$!$1/* $2 */!gm;

    # Mark some comments for special treatment later
    $source =~ s!/\* +---!/*---X_X!g;

    # 'else' followed by a single-line comment, followed by
    # a brace on the next line confuses BSD indent, so we push
    # the comment down to the next line, then later pull it
    # back up again.  Add space before _PGMV or indent will add
    # it for us.
    # AMD: A symptom of not getting this right is that you see errors like:
    # FILE: ../../../src/backend/rewrite/rewriteHandler.c
    # Error@2259:
    # Stuff missing from end of file
    $source =~ s!(\}|\h)else\h*(/\*)(.*\*/)\h*$!$1else\n    $2 _PGMV$3!gm;

    # Indent multi-line after-'else' comment so BSD indent will move it
    # properly. We already moved down single-line comments above.
    # Check for '*' to make sure we are not in a single-line comment that
    # has other text on the line.
    $source =~ s!(\}|\h)else\h*(/\*[^*]*)\h*$!$1else\n    $2!gm;

    # remove trailing whitespace
    $source =~ s/\h+$//gm;

    # detab
    $source = detab($source);

    # Work around bug where function that defines no local variables misindents
    # switch() case lines and line after #else.  Do not do for struct/enum.

    # This could probably be written more perlishly. AMD
    # The original awk code puts the dummy line *before* the brace -
    # is that really what's wanted? It seems weird.  I put it after
    # and it seems to work better anyway. AMD
    my @srclines = split(/\n/,$source);
    foreach my $lno (1..$#srclines)
    {
        my $l2 = $srclines[$lno];
        next unless $l2 =~ /^\{\h*$/;
        my $l1 = $srclines[$lno - 1];

        # find first non-blank line before brace
        foreach my $l1no (reverse 0 .. $lno-2)
        {
            last if $l1 =~ /\S/;
            $l1 = $srclines[$l1no];
        }
        next if $l1 =~ m!=|/|^(struct|enum|\h*typedef|extern\h+"C")!;
        $srclines[$lno] = "$l2\nint pgindent_func_no_var_fix;";
    }
    $source = join("\n",@srclines) . "\n"; # make sure there's a final NL

    # diff($bsource,$source,"-wu");

    # Prevent indenting of code in 'extern "C"' blocks.
    # we replace the braces with comments which we'll reverse later
    my $ec_start = '/* Open extern "C" */';
    my $ec_end = '/* Close extern "C" */';
    $source =~s!(^#ifdef\h+__cplusplus.*\nextern\h+"C"\h*\n)\{\h*$!$1$ec_start!gm;
    $source =~ s!(^#ifdef\h+__cplusplus.*\n)\}\h*$!$1$ec_end!gm;

    # Protect backslashes in DATA().
    $source =~  s!^(DATA\(.*)$!/*$1*/!gm;

    # Protect wrapping in CATALOG().
    $source =~ s!^(CATALOG\(.*)$!/*$1*/!gm;

    $source =~ s!^\h+typedef enum!typedef enum!gm
      if $sourcename =~ 'libpq-(fe|events).h$';

    # diff($bsource,$source,"-wu");

    # run indent
    $source = run_indent($sourcename, $source, $typedefs);
    return if $source eq "";

    # Restore DATA/CATALOG lines.
    $source =~ s!^/\*((DATA|CATALOG)\(.*)\*/$!$1!gm;

    # Remove tabs and retab with four spaces.
    $source = entab($source);

    #diff($bsource,$source,"-u");

    # put back braces for extern "C"
    $source =~ s!^/\* Open extern "C" \*/$!{!gm;
    $source =~ s!^/\* Close extern "C" \*/$!}!gm;

    # remove special comment marker
    $source =~ s!/\*---X_X!/* ---!g;

    # Workaround indent bug for 'static'.
    $source =~ s!^static\h+!static !gm;

    # diff ($bsource,$source,"-u");

    # Remove too much indenting after closing brace.
    $source =~ s!^\}\t\h+!}\t!gm;

    # Indent single-line after-'else' comment by only one tab.
    $source =~ s!(\}|\h)else\h+(/\*.*\*/)\h*$!$1else\t$2!gm;

    # Pull in #endif comments.
    $source =~ s!^\#endif\h+/\*!#endif   /*!gm;

    # Work around misindenting of function with no variables defined.
    $source =~ s!^\h*int\h+pgindent_func_no_var_fix;\h*\n{1,2}!!gm;

    # Add space after comments that start on tab stops.
    # The original comment above doesn't describe what is actually done,
    # which is to insert a tab *before* a comment that's not preceded by
    # whitespace. I have preserved the behaviour. AMD.
    $source =~ s!(\S)(/\*.*\*/)$!$1\t$2!gm;

    # Move trailing * in function return type.
    $source =~ s!^([A-Za-z_]\S*)\h+\*$!$1 *!gm;

    # Remove blank line between opening brace and block comment.
    $source =~ s!(\t*\{\n)\n(\h+/\*)$!$1$2!gm;

    # Pull up single-line comment after 'else' that was pulled down above
    $source =~ s!else\n\h+/\* _PGMV!else\t/*!g;

    # Remove trailing blank lines
    $source =~ s!\n+\z!\n!;

    # Remove blank line(s) before #else, #elif, and #endif
    $source =~ s!\n\n+(\#else|\#elif|\#endif)!\n$1!g;

    # Add blank line before #endif if it is the last line in the file.
    $source =~ s!\n(#endif.*)\n\z!\n\n$1\n!;

    #  Move prototype names to the same line as return type.  Useful for ctags.
    #  Indent should do this, but it does not.  It formats prototypes just
    #  like real functions.

    # diff ($bsource,$source,"-u");

    my $ident = qr/[a-zA-Z_][a-zA-Z_0-9]*/;
    my $comment = qr!/\*.*\*/!;

    $source =~ s!
					(\n$ident[^(\n]*)\n                  # e.g. static void
					(
						$ident\(\n?                      # func_name( 
						(.*,(\h*$comment)?\n)*           # args b4 final ln
						.*\);(\h*$comment)?$             # final line
					)
				!$1 . (substr($1,-1,1) eq '*' ? '' : ' ') . $2!gmxe;

    # Fix indenting of typedef caused by __cplusplus in libpq-fe.h
    # and libpq-events.h
    $source =~ s!^\h+typedef enum!typedef enum!gm
      if $sourcename =~ 'libpq-(fe|events).h$';

    write_source($sourcename,$source);

}

sub read_source
{
    my $srcname = shift;
    my $srcfile;
    my $source;

    open($srcfile,$srcname) || die "opening $srcname: $!";
    local($/)=undef;
    $source=<$srcfile>;
    close($srcfile);
    return $source;
}

sub write_source
{
    my $sourcename = shift;
    my $source = shift;
    my $fh;

    open($fh,">$sourcename") || die "opening $sourcename: $!";
    print $fh $source;
    close($fh);
}

sub run_indent
{
    my $srcname = shift;
    my $source = shift;
    my $typedefs = shift;

    # get the typedefs that occur in this source file
    my @srctypedefs = grep {$source =~ /\b$_\b/} @$typedefs;
    s/^/-T/ foreach (@srctypedefs);

    my $cmd = "$indent $indent_opts $extra_opts " . join(" ", @srctypedefs);

    #	print "cmd: $cmd\n";

    my $fh = new File::Temp(TEMPLATE => "pgsrcXXXXX");
    my $filename = $fh->filename;
    print $fh $source;
    $fh->autoflush(1);

    my $indentout = `$cmd $filename 2>&1`;

    if ($? || length($indentout) > 0)
    {
        print STDERR  "FILE: $srcname\n",$indentout;

        #		system("cat $filename >&2");
        return "";
    }

    unlink "$filename.BAK";

    my $nsrc;
    open($nsrc,$filename);
    local($/)=undef;
    $source=<$nsrc>;

    return $source;

}

# XXX Ideally we'd implement detab/entab in pure perl.

sub detab
{
    my $source = shift;
    my $fh = new File::Temp(TEMPLATE => "pgdetXXXXX");
    my $filename = $fh->filename;
    print $fh $source;
    $fh->autoflush(1);
    my $detab;
    open($detab,"$entab -d -t4 -qc $filename |");
    local($/)=undef;
    $source = <$detab>;
    return $source;
}

sub entab
{
    my $source = shift;
    my $fh = new File::Temp(TEMPLATE => "pgentXXXXX");
    my $filename = $fh->filename;
    print $fh $source;
    $fh->autoflush(1);
    my $entabf;
    open($entabf,"$entab -d -t8 -qc $filename | $entab -t4 -qc |");
    local($/)=undef;
    $source = <$entabf>;
    close($entabf);
    return $source;
}

# for development diagnostics
sub diff
{
    my $before = shift;
    my $after = shift;
    my $flags = shift || "";

    print STDERR "running diff\n";
    my $bfh = new File::Temp(TEMPLATE => "pgdiffbXXXXX");
    my $afh = new File::Temp(TEMPLATE => "pgdiffaXXXXX");
    my $bfname = $bfh->filename;
    my $afname = $afh->filename;
    print $bfh $before;
    print $afh $after;
    $bfh->autoflush(1);
    $afh->autoflush(1);
    system("diff $flags $bfname $afname >&2");
}

sub run_build
{

    eval "use LWP::Simple;";

    my $code_base = shift || '.';
    my $save_dir = getcwd();

    # look for the code root
    foreach (1..5)
    {
        last if -d "$code_base/src/tools/pgindent";
        $code_base = "$code_base/..";
    }

    die "no src/tools/pgindent directory in $code_base"
      unless -d "$code_base/src/tools/pgindent";

    chdir  "$code_base/src/tools/pgindent";

    my $rv = getstore("http://buildfarm.postgresql.org/cgi-bin/typedefs.pl","tmp_typedefs.list");

    die "fetching typedefs.list" unless is_success($rv);

    $ENV{PGTYPEDEFS}= abs_path('tmp_typedefs.list');

    $rv = getstore("ftp://ftp.postgresql.org/pub/dev/indent.netbsd.patched.tgz",
        "indent.netbsd.patched.tgz");

    die "fetching indent.netbsd.patched.tgz" unless is_success($rv);

    # XXX add error checking here

    mkdir "bsdindent";
    chdir "bsdindent";
    system("tar -z -xf ../indent.netbsd.patched.tgz");
    system("make >/dev/null 2>&1");

    $ENV{PGINDENT} = abs_path('indent');

    chdir "../../entab";

    system("make >/dev/null 2>&1");

    $ENV{PGENTAB} = abs_path('entab');

    chdir $save_dir;

}

sub build_clean
{
    my $code_base = shift || '.';

    # look for the code root
    foreach (1..5)
    {
        last if -d "$code_base/src/tools/pgindent";
        $code_base = "$code_base/..";
    }

    die "no src/tools/pgindent directory in $code_base"
      unless -d "$code_base/src/tools/pgindent";

    chdir "$code_base";

    system("rm -rf src/tools/pgindent/bsdindent");
    system("git clean -q -f src/tools/entab src/tools/pgindent");

}

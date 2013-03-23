#!/usr/bin/perl
use strict;

#   Copyright 2013 Tong-Wing
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

my $dpkgroot = "/var/lib/dpkg";
my $pkglog = "$dpkgroot/pkghist.log";
my $verbose = 0;

if (@ARGV<1) {
	my ($self) = (split /[\\\/]/, $0)[-1];
	print <<__EOF__;
Usage: $self [-l] [-u] [-v] [-f histfile]

Commands:
	-u                        Update package status
	-l                        List package history
	-v                        Verbose
	-f <histfile>             Specify a history file used for tracking

Example:
	$self -u -f ~/pkghist.log
	$self -l -f ~/pkghist.log

__EOF__
	exit;
}

my $action;
while ($ARGV[0]) {
	$_ = shift @ARGV;
	if    (/^-l$/) { $action = "list"; } 
	elsif (/^-u$/) { $action = "update"; }
	elsif (/^-v$/) { $verbose = 1; }
	elsif (/^-f$/) { $pkglog = shift @ARGV; }
	else { print "Ignoring unknown option <$_>\n"; }
}

if (!-f $pkglog) {
	print STDERR "> Running for the first time. Saving package info...\n" if ($verbose);

	my @rec = &QueryPackages();
	open OUTFILE, "> $pkglog" or die "Can't open $pkglog for writing";
	foreach my $line (@rec) {
		my @line = @{$line};
		$_ = join "\t", @line;
		print OUTFILE "$_\n";
	}
	close OUTFILE;
}

my %fntable = (
	"list"   => \&ListLogFile,
	"update" => \&UpdateLogFile
);

if ($fntable{$action}) {
	$fntable{$action}->();
} else {
	print "No action specified\n";
}

exit;

sub ListLogFile {

	print STDERR "> Reading log file\n" if ($verbose);

	my @old = &ReadLog();
	
	# create indices
	my @index = ();
	for (my $i=0; $i<@old; $i++) {
		$index[$i] = $i;
	}

	# order1: sort by package, then by date
	my @order1 = sort { 
		my @linea = @{$old[ $a ]};
		my @lineb = @{$old[ $b ]};
		return ($linea[1] cmp $lineb[1]) || ($linea[0] <=> $lineb[0]);
	} @index;

	# generate reverse lookup index for order1
	# so that given an index in @old, we know where in @order1 points to it
	my @rindex = ();
	for (my $i=0; $i<@order1; $i++) {
		$rindex[ $order1[$i] ] = $i;
	}
	
	# order2: reverse sort by date
	my @order2 = sort { 
		my @linea = @{$old[ $a ]};
		my @lineb = @{$old[ $b ]};
		return ($lineb[0] <=> $linea[0]);
	} @index;

	my $lastdate = "";
	foreach my $i (@order2) {
		my ($mtime, $pkg, $ver, $stat) = @{$old[$i]};
		
		my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) =
			localtime($mtime);
		my $mdate = sprintf "%04d-%02d-%02d", $year+1900, $mon+1, $mday;
		my $mftime = sprintf "%02d:%02d", $hour, $min;

		if ($mdate ne $lastdate) {
			my @weekofday = qw( Sun Mon Tue Wed Thu Fri Sat );
			print "\n$mdate ($weekofday[$wday])\n\n";
			$lastdate = $mdate;
		}

		my ($stat1, $stat2);
		my $j = $rindex[$i];
		# sanity check. comment out after testing
#		die if ($old[ $order1[$j] ] != $old[ $i ]);
		
		# get previous pkg entry
		my ($mtime0, $pkg0, $ver0, $stat0) = @{$old[ $order1[$j-1] ]};
		if ($pkg0 eq $pkg) {

			if ($ver eq "") { $stat1 = "purged"; }
			elsif ( ($stat0 =~ /^deinstall/ || $stat0 eq "") && $stat =~ /^install/) { $stat1 = "reinstall"; }
			elsif ($stat =~ /^deinstall/) { $stat1 = "uninstall"; }
			elsif ($ver ne $ver0 && $stat0 ne "") { $stat1 = "upgrade"; }
			elsif ($stat ne $stat0) { $stat1 = "stat change"; $stat2 = "[$stat]"; }
			else { $stat1 = "unknown"; }
			
		} else {
			if ($stat =~ /^deinstall/) { $stat1 = "uninstall"; }
		}
			
#		print "$stat1\t$mftime\t$pkg ($ver) [$stat]\n";
		$stat1 = "$stat1>" if ($stat1);
		$_ = sprintf "%14s%6s  %s (%s) %s", $stat1, $mftime, $pkg, $ver, $stat2;
		print "$_\n";
	}

}

sub UpdateLogFile {

	print STDERR "> Reading existing info\n" if ($verbose);
	my @changes = ();

	# read from log
	my @old = &ReadLog();
	my %old = ();
	foreach my $line (@old) {
		my ($mtime, $pkg, $ver, $stat) = @{$line};

		# skip if this entry is older than an existing one
		next if ( $old{$pkg}{"mtime"} && $old{$pkg}{"mtime"}>$mtime );
			
		# else overwrite with newer entry
		$old{ $pkg }{ "mtime" } = $mtime;
		$old{ $pkg }{ "ver"   } = $ver;
		$old{ $pkg }{ "stat"  } = $stat;
	}

	# query current package list
	my @new = &QueryPackages();
	my %new = ();
	foreach my $line (@new) {
		my ($mtime, $pkg, $ver, $stat) = @{$line};
		
		$new{ $pkg }{ "mtime" } = $mtime;
		$new{ $pkg }{ "ver"   } = $ver;
		$new{ $pkg }{ "stat"  } = $stat;
	}

	# first pass: check new against old - new entries, changed items
	foreach my $line (@new) {
		my ($mtime, $pkg, $ver, $stat) = @{$line};

		if ($old{$pkg} &&
				$old{$pkg}{"mtime"} == $mtime &&
				$old{$pkg}{"ver"} == $ver &&
				$old{$pkg}{"stat"} == $stat) {
			# no change to entry
		} else {
			push @changes, $line;
	if ($stat =~ /^deinstall/) {
		print "Uninstalled> ";
	} else {
		print "Changed/added> ";
	}
	print localtime($mtime) . " $pkg (".$ver.")\n";
		}
	}

	# second pass: check old against new - so that we know what is removed
	foreach my $line (@old) {
		my ($mtime, $pkg, $ver, $stat) = @{$line};

		# skip deprecated entries
		next if ($old{$pkg}{"mtime"}!=$mtime);

		# skip entries that are purged
		next if (!$old{$pkg}{"stat"});
		
		if ($new{$pkg}) {
			# already present
		} else {
			# see if can stat the list file
			my $listfile = "$dpkgroot/info/$pkg.list";
			my @stat = stat $listfile;
			
			my ($mtime1);
			if (@stat) { 
				$mtime1 = $stat[9];
			} else {
		 		$mtime1 = time;
			}

			push @changes, [$mtime1, $pkg, "", ""];
	print "Purged> ".localtime($mtime1) . " $pkg (".$ver.")\n";
		}
	}

	# add changed entries to log
	if (@changes) {
		print STDERR "> Writing " . scalar(@changes) . " changes to $pkglog\n" if ($verbose);
		open OUTFILE, ">> $pkglog" or die "Can't open $pkglog for writing";
		foreach my $line (@changes) {
			my @line = @{$line};
			$_ = join "\t", @line;
			print OUTFILE "$_\n";
		}
		close OUTFILE;
	} else {
		print STDERR "> No changes detected\n" if ($verbose);
	}

}

exit;

#############################################################################

sub ReadLog {
	my @rec = ();

	open INFILE, "< $pkglog" or die "Can't open $pkglog for reading";
	while ($_ = <INFILE>) {
		chomp;
		my ($mtime, $pkg, $ver, $stat) = split /\t/;
		push @rec, [$mtime, $pkg, $ver, $stat];
	}
	close INFILE;

	return @rec;
}

sub QueryPackages {
	open PIPE, "dpkg-query -W -f='\${Status}\t\${Package}\t\${Version}\n' |" or
		die "Unable to run dpkg-query";
	my @result = <PIPE>;
	close PIPE;

	my @rec = ();
	while ($_ = shift @result) {
		chomp;
		my ($stat, $pkg, $ver) = split /\t/;

		# get date/time from .list file
		my $listfile = "$dpkgroot/info/$pkg.list";
		my @stat = stat $listfile;
		
		my ($mtime);
		if (@stat) { 
			$mtime = $stat[9];
		} else {
			print STDERR "> Warning: unable to stat $listfile. Using current time\n" if ($verbose);
	 		$mtime = time;
		}

		push @rec, [$mtime, $pkg, $ver, $stat];
	}

	return @rec;
}


#!/usr/bin/perl -w
############################################
#  ff_cache_find.pl - reads firefox cache, displays metadata for each
#   cache entry that matches search criteria
#	Params:	Mapfile - path to _CACHE_MAP_ file
#		--search=[Search term] (optional)
#			regex to match in cache metadata entries
#			(default is .*)
#		--recover=[directory] (optional)
#			directory to recover cache entries into
#			without this, only the cache metadata is viewed
#######
# Version History
#	John Ritchie	Initial release (0.1)	10/6/2011
#	John Ritchie	0.2: Update for FF >=4, bugfix	11/4/2011
#	John Ritchie	0.3: Update to correctly handle external metadata	3/9/2012
#######
use strict;

#  for uncompress of gzipped cache content
use Compress::Raw::Zlib;
#  for interpreting Content-Type headers
use MIME::Types 'by_mediatype';

# define some values (from Firefox nsDiskCacheMap.h)
my $eReservedMask =		0x4C000000;
my $eLocationSelectorMask =	0x30000000;
my $eLocationSelectorOffset =	28;
my $eExtraBlocksMask =		0x03000000;
my $eExtraBlocksOffset =	24;
my $eBlockNumberMask =		0x00FFFFFF;
my $eFileGenerationMask =	0x000000FF;
my $eFileSizeMask =		0x00FFFF00;
my $eFileSizeOffset =		8;
my $eFileReservedMask =		0x4F000000;


#  some global config variables
my $cache_dir = undef;
my $map_file = undef;
my $search_term = '.*';
my $recover_dir = undef;

# other global variables

#  debug flag. set to 1 for extra messages
my $debug = 0;

# flags to stop asking the same question
my $alwaysno = 0;
my $alwaysyes = 0;

# list of hash refs to store mapfile information
my @cache_map = ();

#  variables to store cache version in
my $mVer_major;
my $mVer_minor;

#  Now let's go do stuff
#  figure out what command-line options were passed along
&parse_options;

#  set cache_dir from $map_file by extracting directory from it
$cache_dir = $map_file;

#  if we don't have a directory prepended then it's this directory
my @elems = split (/\//, $cache_dir);
if ((scalar @elems) < 2)
{
	$cache_dir = ".";
}
else
{
	$cache_dir =~ s/^(.*)\/.*/$1/;
}


#  open and read map file, results will be stored in @cache_map
&read_map($map_file);

foreach (@cache_map)
{
	&print_meta($_, $search_term);
}  # end foreach


exit;
#  end main()


##########  Subroutines  ###############

####################################
#  sub print_meta
#	Given a hash reference and a search term, prints metadata information
#	for cache entries that match the search term
#	If recover dir defined, offers choices to recover cache entry
###
sub print_meta
{
	my $entry_ref = shift;
	my $search = shift;

	return unless (defined ${$entry_ref}{"m_filename"});

	unless (-f ${$entry_ref}{"m_filename"})
	{
		die "File ${$entry_ref}{'m_filename'} doesn't exist\n";
	}

	${$entry_ref}{'m_blockcount'} = 0 unless (defined ${$entry_ref}{'m_blockcount'});
	${$entry_ref}{'m_startblock'} = 0 unless (defined ${$entry_ref}{'m_startblock'});


	#  update entry_ref with cache_read
	my $match = &cache_read($entry_ref, "m", $search);


	if ($match)
	{
		#  print "-----------------------\n";
		#  print "Request String: " . ${$entry_ref}{'m_request_string'} . "\n";
		#  print "Create time: " . localtime(${$entry_ref}{'m_create_time'}) . "\n";
		#  print "Last Modified time: " . localtime(${$entry_ref}{'m_mod_time'}) . "\n";
		#  print "Expire time: " . localtime(${$entry_ref}{'m_expire_time'}) . "\n";
		#  print "Fetch count: " . ${$entry_ref}{'m_fetch_count'} . "\n";
		#  print "Request Size: " . ${$entry_ref}{'m_request_size'} . "\n" if ($debug);
		#  print "Info Size: " . ${$entry_ref}{'m_info_size'} . "\n" if ($debug);
		#  print "Cache File: " . ${$entry_ref}{'m_cache_file'} . "\n" if ($debug);

		my $info_string = ${$entry_ref}{'m_info_string'};
		#  make it so it prints pretty
		$info_string =~ s/\r*\n/\n\t/g;

		#  print "Server Response: " . $info_string . "\n";

		#  do we want to ask about extracting this?
		if ((defined $recover_dir) && (!($alwaysno)))
		{
			my $yesplease = 0;
			my $alwaysyes = 1;  # added to skip question and always dump data to recover_dir
			unless ($alwaysyes)
			{
				print "Do you want to recover this cache item?\n";
				print "[Y]es, [N]o, ne[V]er, [A]lways, [Q]uit (default N): ";
				### debugging
##				my $resp = "";
				my $resp = <STDIN>;
				chomp $resp;
				if ($resp =~ /^[ya]/i)
				{
					$alwaysyes = 1 if ($resp =~ /^a/i);
					$yesplease = 1;
				}
				elsif ($resp =~ /^q/i)
				{
					exit;
				}
				elsif ($resp =~ /^v/i)
				{
					$alwaysno = 1;
				}
			}
			if (($alwaysyes) || ($yesplease))
			{
				# recover file
				&recover($entry_ref);
			}
		

		} # end if recover_dir, etc.
	} # end if $match


}  # end sub print_meta

#########################################
#  sub read_map - given a CACHE_MAP filename, opens and reads it
#   attributes are stored on @cache_map global list
#####
sub read_map
{

my $map_file = shift;

my $hash_num;
my $eviction;
my $data_loc;
my $metadata_loc;

open MAPFILE, $map_file or die "Unable to open Map file: $!\n";

#  according to Firefox nsDiskCacheMap.h, header is:
#	0-3	mVersion
#	4-7	mDataSize
#	8-11	mEntryCount
#	12-15	mIsDirty
#	16-19	mRecordCoun
#	20-147	mEvictionRank array (32 buckets, 4 bytes each)
#	148-275	mBucketUsage array (32 buckets, 4 bytes each)

# will need these for version-specific functionality, if any
# mVersion findings:
#	FF6 on Win7: 00 01 00 13 (1 19)
#	Win XP 3.?: 00 01 00 0C (1 12)
#	Mac 3.?: 00 01 00 0C (1 12)
#	Linux 2.?: 00 01 00 08 (1 8)
#
##  From different versions of firefox nsDiskCache.h:
#	FF2.? 00 01 00 08
#	Mozilla 1.7 00 01 00 05
#	Mozilla 1.8.0	00 01 00 06
#	Mozilla 1.8 00 01 00 08
#	Mozilla 1.9.1	00 01 00 0B (Firefox 3.5)
#	Mozilla 1.9.2	00 01 00 0C (Firefox 3.6)
#	Mozilla 2.0 (FF4.0)	00 01 00 13
#    I'm not sure of the Mozilla vs. Firefox version numbering, but the
#    00 01 00 13 is also present in FF6 and FF7 cache


my $header = "";
read (MAPFILE, $header, 276);
my $dirty = unpack('L>4', substr ($header, 12, 4));

print "Firefox cache was not properly flushed so may be corrupted\n" if ($dirty);

$mVer_major = unpack('S>2', substr ($header, 0, 2));
$mVer_minor = unpack('S>2', substr ($header, 2, 2));

print "Cachefile Version: " . $mVer_major . "." . $mVer_minor . "\n" if ($debug);

if (eof(MAPFILE))
{
	print "Cache MAP file is empty\n";
	return;
}

my $bucket = "";
my $bucketsize = 16; # 4 4-byte values
until (eof(MAPFILE))
{

	#  make a new %entry and initialize it
	my %entry = (
		"m_filename",	undef,
		"d_filename",	undef,
		"m_startblock",	undef,
		"d_startblock",	undef,
		"m_blockcount",	undef,
		"d_blockcount",	undef,
	);

	unless (read (MAPFILE, $bucket, $bucketsize) == $bucketsize) 
	{
		print "short read on $map_file, quitting...\n";
		close MAPFILE;
		exit;
	}

	#  these need to be big-endian on my Mac - is that always true?
	($hash_num, $eviction, $data_loc, $metadata_loc) = unpack ('L>4 L>4 L>4 L>4', $bucket);

	#  if $hash_num == 0 we don't have anything so skip it
	next unless $hash_num;

	#  copy of nsDiskCacheMap.h ValidRecord check
	if (($data_loc & $eReservedMask) || ($metadata_loc & $eReservedMask))
	{
		print "Invalid Map record, skipping\n";
		next;
	}

	#  get the location selector (0 .. 3)
	my $meta_location_select = $metadata_loc & $eLocationSelectorMask;
	$meta_location_select = $meta_location_select >> $eLocationSelectorOffset;

	#  create the cache filename
	my $meta_filename = $cache_dir . "/" . sprintf ("%s%03d%s", "_CACHE_", $meta_location_select, "_");


	my $no_meta_flag = 0;

	#  This means metadata is stored in an external file or there is none
	#    I've not yet seen this in my test cases
	if ($meta_location_select == 0)
	{
		#  get the generation number
		my $gen = $metadata_loc & $eFileGenerationMask;

		# generate external file name - this is version dependent: FF >= 4 has subdirectories
		if (($mVer_major == 1) && ($mVer_minor < 19))
		{
			$meta_filename = $cache_dir . "/" . uc(sprintf("%08s", sprintf("%x", $hash_num))) . "m" . sprintf("%02d", $gen);
		}
		else
		{
			$meta_filename = uc(sprintf("%08s", sprintf("%x", $hash_num))) . "m" . sprintf("%02d", $gen);
			#  FF >= 4 has subdirectories, so inject some path into this
			substr ($meta_filename, 1, 0, "/");
			substr ($meta_filename, 4, 0, "/");
			$meta_filename = $cache_dir . "/" . $meta_filename;
		}

		if ($gen < 1)
		{
			#  if generation == 0 then it means no metadata was stored?
			#   we should never see this with metadata but I've
			#   seen it with FF2 on linux (dirty flag was set)
			print "No metadata stored!\n" if ($debug);
			$no_meta_flag = 1;
			$meta_filename = undef;
		}
		else
		{
###			print "external metadata: " . $meta_filename . "\n";
			#  set start block to 0
			$entry{"m_startblock"} = 0;
			#  set block count to 1
			$entry{'m_blockcount'} = 1;
			#   set blocksize to the size of the file
			$entry{'m_blocksize'} = (-s $meta_filename);

###			print "Start: " . $entry{'m_startblock'} . " count: " . $entry{'m_blockcount'} . " Size: " . $entry{'m_blocksize'} . "\n";

		}
	}
	else	#  metadata stored in a CACHE_00? file
	{
		#  get the metadata starting block number
		my $meta_start_block = $metadata_loc & $eBlockNumberMask;

		$entry{"m_startblock"} = $meta_start_block;

		#  get the block count
		my $meta_blocks = (($metadata_loc & $eExtraBlocksMask) >> $eExtraBlocksOffset) + 1;
		$entry{"m_blockcount"} = $meta_blocks;

##		print "Block count: " . $meta_blocks . "\n";

		#  this doesn't seem useful - skipping it
#		 my $meta_size = ($metadata_loc & $eFileSizeMask) >> $eFileSizeOffset;
#		 print "Metadata file size = " . $meta_size . "\n";
	}

	$entry{"m_filename"} = $meta_filename;

	#  Now work on the data elements
	my $data_location_select = $data_loc & $eLocationSelectorMask;
	$data_location_select = $data_location_select >> $eLocationSelectorOffset;

	my $data_filename = $cache_dir . "/" . sprintf ("%s%03d%s", "_CACHE_", $data_location_select, "_");


	#  per Firefox nsDiskCacheMap.h
	#   this is commented out because it doesn't seem consistent and
	#   hasn't been useful
	#unless ($data_loc & $eFileReservedMask)
	#{
	#	print "Data Saved Externally?\n";
	#}

	#  this means data is stored in an external file or there is none - both valid cases
	if ($data_location_select == 0)
	{
		#  get the generation number
		my $gen = $data_loc & $eFileGenerationMask;

		# generate external file name - this is version dependent: FF >= 4 has subdirectories
		if (($mVer_major == 1) && ($mVer_minor < 19))
		{
			$data_filename = $cache_dir . "/" . uc(sprintf("%08s", sprintf("%x", $hash_num))) . "d" . sprintf("%02d", $gen);
		}
		else
		{
			$data_filename = uc(sprintf("%08s", sprintf("%x", $hash_num))) . "d" . sprintf("%02d", $gen);
			#  FF >= 4 has subdirectories, so inject some path into this
			substr ($data_filename, 1, 0, "/");
			substr ($data_filename, 4, 0, "/");
			$data_filename = $cache_dir . "/" . $data_filename;
		}

		# if generation == 0 then it means there was no data stored
		#   e.g. http status return code = 302
		if ($gen < 1)
		{
			$data_filename = undef;
		}
	}
	else	#  data stored in CACHE_00? file
	{
		#  get data beginning block number
		my $data_start_block = $data_loc & $eBlockNumberMask;
		$entry{"d_startblock"} = $data_start_block;

		#  get data block count;
		my $data_blocks = (($data_loc & $eExtraBlocksMask) >> $eExtraBlocksOffset) + 1;
		$entry{"d_blockcount"} = $data_blocks;

		#  not useful
		# my $data_size = ($data_loc & $eFileSizeMask) >> $eFileSizeOffset;
		# print "Data file size = " . $data_size . "\n";
	}

	$entry{"d_filename"} = $data_filename;


#  if there's no meta data but there is a data entry then this is stranded but
#  recoverable
if (($no_meta_flag ) && (defined $entry{"d_filename"}))
{
	print "Stranded Data Filename: " . $entry{"d_filename"};
	print " Start block: " . $entry{"d_startblock"} if (defined $entry{"d_startblock"});
	print "Data block count: " . $entry{"d_blockcount"} if (defined $entry{"d_blockcount"});
	print "\n";
}

	push @cache_map, \%entry;

}	# end until{}

close MAPFILE;

return;
}  # end sub read_map


#########################################
# sub cache_read - given params:
#	reference to hash of cache entry
#	m/d flag
#	search term
#  subroutine opens and reads appropriate cache file and sets
#    attributes in the hash of cache entry, returning 1 if it
#    matches search term
#####
sub cache_read
{

#  these are hard-coded rather than using Mozilla's fancy shift logic
my %blocksizes = (
	'',	0,
	'_CACHE_001_',	256,
	'_CACHE_002_',	1024,
	'_CACHE_003_',	4096);

my %mapsizes = (
	'',	0,
	'_CACHE_001_',	16384,
	'_CACHE_002_',	4096,
	'_CACHE_003_',	1024);

my $entry_ref = shift;

my $cache_file = '';
my $offset = '';
my $blocks = '';
my $bitmap = '';
my $blocksize = 0;
my $mapsize = 0;

my $meta_data = shift;
my $search = shift;

unless ($meta_data =~ /[md]/i)
{
	die "Invalid meta/data flag: must be \"m\" or \"d\"\n";
}

#  if we're dumping metadata, set variables from "m" values
if ($meta_data =~ /m/i)
{
	$cache_file = ${$entry_ref}{'m_filename'};
	$offset = ${$entry_ref}{'m_startblock'};
	#  this gets set to 1 if it's an external metadata file
	$blocks = ${$entry_ref}{'m_blockcount'};
	#  this gets set to the file size if it's an external metadata file
	$blocksize = (defined ${$entry_ref}{'m_blocksize'}) ? ${$entry_ref}{'m_blocksize'} : 0;
}
#  else if we're dumping actual data, set variables from "d" values
else
{
	#  if there's no data filename defined then it must have been empty
	#   like a 302 found or something like that
	return "" unless (defined ${$entry_ref}{'d_filename'});

	$cache_file = ${$entry_ref}{'d_filename'};

	#  if offset and blocks aren't set it's probably an external file
	$offset = (defined ${$entry_ref}{'d_startblock'}) ? ${$entry_ref}{'d_startblock'} : 0;
	$blocks = (defined ${$entry_ref}{'d_blockcount'}) ? ${$entry_ref}{'d_blockcount'} : 0;
}

my $filename = $cache_file;
$filename =~ s/.*\/(.*)/$1/;

if (defined $blocksizes{$filename})
{
	$blocksize = $blocksizes{$filename};
}

if (defined $mapsizes{$filename})
{
	$mapsize = $mapsizes{$filename};
}

my $readsize = 0;
#   if we're grabbing a data portion then try to use a content_length
#   set by a previous call to get the metadata
if (($meta_data =~ /d/i) && (defined ${$entry_ref}{'d_content_length'}))
{
	$readsize = ${$entry_ref}{'d_content_length'};
}
else
{
	$readsize = $blocksize * $blocks;
}

open CACHEFILE, $cache_file or die "Unable to open cache file $cache_file: $!\n";

# jump past header - but not if we're reading a standalone file (and fetching data)

#  according to nsDiskCacheBlockFile.cpp, first 4096 bytes are an allocation bit map
#    Oooks!  up until FF 4, then each cachefile has a different header size!
#   http://mxr.mozilla.org/mozilla2.0/source/netwerk/cache/nsDiskCacheMap.h

if (($mVer_major == 1) && ($mVer_minor < 19))
{
	read (CACHEFILE, $bitmap, 4096) if ($blocksize > 0);
}
else
{
	read (CACHEFILE, $bitmap, $mapsize) if ($mapsize > 0);
}


#  find beginning of data we're interested in
#  if we're reading a standalone file then blocksize should be 0 so this should work
seek (CACHEFILE, $blocksize * $offset, 1);

my $data = "";

my $readcount = read (CACHEFILE, $data, $readsize);
unless ($readcount == $readsize)
{
	#  read will return < requested bytes if it hits EOF during read
	unless ((defined $readcount) && ($readcount > 0))
	{
		print "Read error on $cache_file: $! $readcount bytes read\n";
		close CACHEFILE;
		print "\tseek offset: " . $offset . " blocks: " . $blocks . " of size: " . $blocksize . "\n";
		next;
	}
}

#  if we're looking for metadata, not data
if ($meta_data =~ /m/i)
{
	#  should be "brief" or "full" output format

	# this copies nsDiskCacheEntry from Firefox nsDiskCacheEntry.h
	my ($hVer_major, $hVer_minor, $location, $fetch_count, $fetch_time, $modify_time, $expire_time, $data_size, $request_size, $info_size) = unpack('S> S> L>4 L>4 L>4 L>4 L>4 L>4 L>4 L>4', $data);

	print "hVer_major = " . $hVer_major . " hVer_minor = " . $hVer_minor . "\n" if ($debug);

	#  this is a sanity check - we need more than one variable to check for sanity
	#  Another sanity check is to check that the $header_version matches the map version
	#  1000 is PIDOMA - what would be a valid upper limit to this?
	if (($hVer_major != $mVer_major) || ($hVer_minor != $mVer_minor) || ($fetch_count > 1000) || ($fetch_count < 1))
	{
		#  don't mess around with these, get outta here
		print "Bogus record?\n" if ($debug);
		return 0;

		#   all the below crap is debugging
		print "Fetch count: " . $fetch_count . "\n" if ($debug);
		print "Cache file: " . $cache_file . "\n" if ($debug);
		print "Position: " . tell(CACHEFILE) . "\n" if ($debug);
		print "Offset: $offset\n" if ($debug);
		print "Blocks: $blocks\n" if ($debug);
		if ($debug)
		{
			print "Meta filename: ${$entry_ref}{'m_filename'}\n";
			print "Meta startblock: ${$entry_ref}{'m_startblock'}\n";
			print "Data filename: ${$entry_ref}{'d_filename'}\n";
			print "Data startblock: ${$entry_ref}{'d_startblock'} , Count: ${$entry_ref}{'d_blockcount'}\n";
		}
		&verify_allocation($bitmap, $offset, $blocks);
		return 0;
	}

	#  we need to do a check that the blockcount from the MAP file is correct
	#  if it's not correct (too small) then try grabbing more data
	#  Update: this may be a workaround for a self-induced bug. May no longer
	#    be necessary
	my $expected_size = ((9*4) + $request_size + $info_size);
	if ($readsize < $expected_size)
	{
		print "READSIZE error: less than expected bytes (" . $expected_size . ") read: " . $readsize . "\n" if ($debug);
		print "\tData bytes read: " . bytes::length($data) . "\n" if ($debug);
		print "\tRequest size: " . $request_size . "\n" if ($debug);
		print "\tInfo size: " . $info_size . "\n" if ($debug);
		print "\tBlock count from MAP file: " . $blocks . "\n" if ($debug);

		#  now grab what's missing if possible
		my $moredata = '';
		if ((read (CACHEFILE, $moredata, $expected_size - $readsize)) == ($expected_size - $readsize))
		{
			$data .= $moredata;
		}
		else
		{
			print "Read error attempting to get more data from $cache_file: $!\n";
			close CACHEFILE;
			next;
		}
	}


	#  grab request string from remaining data
	my $request_string = substr ($data, 9*4, $request_size);

	#  get rid of NULLs
	$request_string =~ s/\0+/ /g;

	#  set this into the hash ref
	${$entry_ref}{'m_request_string'} = $request_string;

	#  grab server return information from remaining data
	my $info_string = substr ($data, (9*4)+$request_size, $info_size);
	#  get rid of NULLs
	$info_string =~ s/\0+/ /g;
	${$entry_ref}{'m_info_string'} = $info_string;


	#  dig some recovery-useful info out of this (filename, content-type, content-length, content-encoding)

	# get filename from request string
	my $destfile = $request_string;

	#  this is broken because of wild URL construction. Really need to
	#   use a URI parser library for this
	$destfile =~ s/.*\/(.*)$/$1/;
	#  get rid of trailing whitespace
	$destfile =~ s/(.*?)\s?$/$1/;
	${$entry_ref}{'d_orig_filename'} = $destfile;

	#  find content-type if available
	my $content_type = '';
	if ($info_string =~ /Content-Type:/)
	{
		$content_type = $info_string;
		$content_type =~ s/.*Content-Type: (.*?)\n.*/$1/s;
		#  get rid of additional optional info after a ";"
		$content_type =~ s/^(.*);.*/$1/;
		${$entry_ref}{'d_content_type'} = $content_type;
	}

	#  find content-length if available
	my $content_length = '';
	if ($info_string =~ /Content-Length:/)
	{
		$content_length = $info_string;
		$content_length =~ s/.*Content-Length: (.*?)\n.*/$1/s;
		${$entry_ref}{'d_content_length'} = $content_length;
	}

	#  find content-encoding if available
	my $content_encoding = '';
	if ($info_string =~ /Content-Encoding:/)
	{
		$content_encoding = $info_string;
		$content_encoding =~ s/.*Content-Encoding: (.*?)\n.*/$1/s;
		#  get rid trailing non-word characters (\r)
		$content_encoding =~ s/\W*$//;
		${$entry_ref}{'d_content_encoding'} = $content_encoding;
	}

	#  set all this stuff into the hash
	${$entry_ref}{'m_create_time'} = $modify_time;
	${$entry_ref}{'m_mod_time'} = $fetch_time;
	${$entry_ref}{'m_expire_time'} = $expire_time;
	${$entry_ref}{'m_fetch_count'} = $fetch_count;
	${$entry_ref}{'m_request_size'} = $request_size;
	${$entry_ref}{'m_info_size'} = $info_size;
	${$entry_ref}{'m_cache_file'} = $cache_file;

	close CACHEFILE;

	#  search against content we want to match - currently searching against either
	#  the request string or the server return info
	if ((${$entry_ref}{'m_request_string'} =~ /$search/i) || (${$entry_ref}{'m_info_string'} =~ /$search/i))
	{
		return 1;	# we found something
	}
	else
	{
		return 0;
	}

}  # end if (metadata)

else	#  we're asking for the actual cache data
{
	close CACHEFILE;
	return $data;
}

}  #end sub cache_read


###########################################################
#  sub recover - parse $entry reference for recovery
#    details and pass them to sub cache_read to fetch data file
#    then opens and write data file
###
sub recover
{
my $entry_ref = shift;
my $filename = "";

my $data = &cache_read($entry_ref, "d", '');

if (length $data == 0)
{
	# print "No data was output, nothing to write!\n";
	return;
}

if (defined ${$entry_ref}{'d_orig_filename'})
{
	$filename = ${$entry_ref}{'d_orig_filename'};
}
else
{
	#  need code here to query user for filename?
	$filename = "Test_out.file";
}

##  do whatever it takes to sanitize the filename for creation on a
##  file system.
#  get rid of everything after ? mark
$filename =~ s/(.*)?\?.*/$1/;

#  strip other bad things (ampersands, semicolons, leading dashes)
$filename =~ s/[&;]/_/g;
$filename =~ s/^-*//;

#  truncate long filename (this is an arbitrary number - PIDOMA)
if (length($filename) > 150)
{
	$filename =~ s/^(.{150}).*/$1/;
}

# determine what type and extension this has or should have

my $ext_match = "";
if (defined ${$entry_ref}{'d_content_type'})
{
	#  determine valid extensions for this file type and whether filename
	#  already contains that extension
	my @extensions = ();
	my $listref = by_mediatype(${$entry_ref}{'d_content_type'});
	foreach (@{$listref})
	{
		my $ext = @{$_}[0];
		push @extensions, $ext;
		if ($filename =~ /\.$ext$/i)
		{
			$ext_match = $ext;
			#  strip extension off of filename
			#  so we can add stuff and put it back later
			$filename =~ s/(.*)\.$ext$/$1/i;
		}
	}

	#  now if we don't have one, set one from the list of valid ones
	if (((scalar @extensions) > 0) && ($ext_match eq ""))
	{
		$ext_match = $extensions[0];
	}
}
else
{
	print "NO Content-Type\n" if ($debug);
}

#  if $filename is empty, now what? Make something up.
$filename = "[no_name]" if ($filename =~ /^$/);

$filename = $recover_dir . "/" . $filename;

#  if we have an extension, put a "." in front of it
if ($ext_match ne "")
{
	$ext_match = "." . $ext_match;
}

#  now loop through versions of this file name, finding a unique one
my $f_index = 0;

while (-f $filename . "[" . $f_index . "]" . $ext_match)
{
	$f_index++;
}

$filename = $filename . "[" . $f_index . "]" . $ext_match;

#  if gzip encoded then decode
if ((defined ${$entry_ref}{'d_content_encoding'}) && (${$entry_ref}{'d_content_encoding'} =~ /^gzip$/i))
{
	# print "Inflating gzipped data...\n";
	my $inflated_data = '';
	my $inflate = new Compress::Raw::Zlib::Inflate(-WindowBits => WANT_GZIP) or print "Cannot create an inflation stream\n";
	my $status = $inflate->inflate($data, $inflated_data);
	if ($status == Z_STREAM_END)
	{
		$data = $inflated_data;
	}
	else
	{
		print "Inflation failed: $status, " . $inflate->msg() . "\n";
		print "Compressed data saved\n";
	}
}


##print "Would write filename $filename\n";
#  write the file
open (OUTFILE, ">$filename") or die "Can't open $filename for writing: $!\n";
print OUTFILE $data;
close OUTFILE;

#  now also create an accompanying metadata file
my $filename2 = $filename . "_metadata";

open (OUTFILE, ">$filename2") or die "Can't open $filename2 for writing: $!\n";

print OUTFILE "Request String: " . ${$entry_ref}{'m_request_string'} . "\n";
print OUTFILE "Create time: " . localtime(${$entry_ref}{'m_create_time'}) . "\n";
print OUTFILE "Last Modified time: " . localtime(${$entry_ref}{'m_mod_time'}) . "\n";
print OUTFILE "Expire time: " . localtime(${$entry_ref}{'m_expire_time'}) . "\n";
print OUTFILE "Fetch count: " . ${$entry_ref}{'m_fetch_count'} . "\n";
print OUTFILE "Request Size: " . ${$entry_ref}{'m_request_size'} . "\n" if ($debug);
print OUTFILE "Info Size: " . ${$entry_ref}{'m_info_size'} . "\n" if ($debug);
print OUTFILE "Cache File: " . ${$entry_ref}{'m_cache_file'} . "\n" if ($debug);

my $info_string = ${$entry_ref}{'m_info_string'};
#  make it so it prints pretty
$info_string =~ s/\r*\n/\n\t/g;

print OUTFILE "Server Response: " . $info_string . "\n";

# print Recovery data too
print OUTFILE "\nRecovered from: " . ${$entry_ref}{'d_filename'} . "\n";
#   Block isn't that useful - a byte offset would be better
##print OUTFILE "\tBlock: " . ${$entry_ref}{'d_startblock'} . "\n";

close OUTFILE;

# after creation we can set the access and mod times of the files to match the last mod time of the cache entry - will cause date sort of directory to be correct

utime ${$entry_ref}{'m_mod_time'}, ${$entry_ref}{'m_mod_time'}, ($filename, $filename2);

} # end sub recover


############################################################
#  sub parse_options
#	digs through @ARGV fo options and sets global values
######
sub parse_options
{

#  check command-line args
&usage unless ((scalar @ARGV) > 0);

# parse arguments
while ((scalar @ARGV) > 0)
{
	my $opt = shift @ARGV;

	#  search term
	if ($opt =~ /^--search/)
	{
		my $st = (split (/=/, $opt))[1];
		if (defined $st)
		{
			$search_term = $st;
		}
		else
		{
			&usage;
		}
	}
	#  recover directory
	elsif ($opt =~ /^--recover/)
	{
		my $rd = (split (/=/, $opt))[1];
		if (defined $rd)
		{
			#  check to make sure this is really a directory
			if (-d $rd)
			{
				$recover_dir = $rd;
			}
			else
			{
				print "Recovery dir $rd not a directory\n";
				&usage;
			}
		}
		else
		{
			&usage;
		}
	}
	#  unknown option
	elsif ($opt =~ /^--/)
	{
		# do a usage here
		print "Unknown option $opt\n";
		&usage;
	}
	else
	{
		$map_file = $opt;
	}

} # end while ARGV

#  check mapfile
unless (defined $map_file)
{
	&usage;
}
unless ( -f $map_file)
{
	print "$0 MAP file $map_file found or not a file\n";
	&usage;
}

}  # end sub parse_options

################################################################
#  sub verify_allocation - a copy of Mozilla's VerifyAllocation
#  function from within nsDiskCacheBlockFile.cpp - given a cache
#  block file bitmap, a start block and a blockcount, verifies
#  that the blocks are allocated
#	This is only used for debugging so far
##
sub verify_allocation
{
my $bitmap = shift;
my $startblock = shift;
my $blockcount = shift;

my $startword = $startblock >> 5;	# Divide by 32
my $startbit = $startblock & 31;	# Modulo by 32

if ($startbit + $blockcount > 32)
{
	print "Illegal values\n";
	return;
}

my $mask = ((0x01 << $blockcount) - 1) << $startbit;

print "Startblock: " . $startblock . " Blockcount: " . $blockcount . "\n";
print "Startword: " . $startword . " Startbit: " . $startbit . "\n";

my $compareword = substr ($bitmap, $startword * 4, 4);
$compareword = unpack('L>4', $compareword);
print "Mask: " . $mask . " Compareword: " . $compareword . "\n";
if (($compareword & $mask) != $mask)
{
	print "Block not allocated\n";
}
else
{
	print "Block is allocated\n";
}

}  # end verify_allocation

################################################################
# sub usage - print usage message and dies
##
sub usage
{

	print "Usage: $0 [mapfile]\n";
	print "\tOptions:\n";
	print "\t\t--search=[search regex] (default is .* - everything)\n";
	print "\t\t\tSearches against query string and server return information, only returning cache entries matching regex.\n";
	print "\t\t--recover=[recovery dir] - directory to recover files into\n";
	print "\t\t\tRecommend recovering into a separate empty directory.\n\t\t\tRecovered items will be date-ordered by cache entry modification dates.\n";
	print "\n";

	exit;

} # end sub usage

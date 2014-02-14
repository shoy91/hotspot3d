package TGI::Mutpro::Preprocess::Calpro;
#
#----------------------------------
# $Authors: Beifang Niu 
# $Date: 2014-01-14 14:34:50 -0500 (Tue Jan 14 14:34:50 CST 2014) $
# $Revision:  $
# $URL: $
# $Doc: $ calculate proximity file for one uniprotid (used by first step)
#----------------------------------
#
#package Calpro;
#
#  Input: Uniprot id
#  Output: 1) File with structure-based proximity data
#          2) File with list of structures where coordinates 
#             can be mapped to Uniprot coordinates
#
# Could get domains in Uniprot sequence and then do alignment of Uniprot 
# domain to PDB sequence and get domain-specific offset
#
# That might 'rescue' some of the structures where coordinates 
# can not be mapped to Uniprot coordinates

#   can make last thing update program does is to check to see if there 
#   are any files in the inProgress/ directory. 
#   If not, mail that it is finished
#
# - dir inProgress/$uniprot
#       inProgress/$uniprot.structures
# - mv  inProgress/$uniprot.structures to validStructures/$uniprot.validStrustures
#       inProgress/$uniprot to proximityFiles/$uniprot.ProximityFile.csv 
#  Get Uniprot object
#  Get Uniprot-defined domains
#  Get all PDB structures
#  Make entry for all positions in structure near a Uniprot-defined domain
#  Make entry for all positions near a heterologous (peptide) chain
#
#
#
# Electrostatic Bonds: 	lengths of around 3.0 Angstroms. 
# Hydrogen Bonds:   	lengths range between 2.6 and 3.5 Angstroms
# Van der Waals:  	lengths range beteen 2.5 and 4.6 Angstroms
# PI Aromatic bond:  	lengths 3.8 Angstroms. 
#----------------------------------
#

use strict;
use warnings;

use Carp;
use Cwd;
use IO::File;
use FileHandle;
use File::Copy;
use LWP::Simple;
use Getopt::Long;

use TGI::Mutpro::Preprocess::Uniprot;
use TGI::Mutpro::Preprocess::PdbStructure;
use TGI::Mutpro::Preprocess::HugoGeneMethods;

sub new {
    my $class = shift;
    my $this = {};
    $this->{_OUTPUT_DIR} = getcwd;
    $this->{_MAX_3D_DIS} = 10;
    $this->{_MIN_SEQ_DIS} = 5;
    $this->{_UNIPROT_ID} = undef;
    $this->{_RESTRICTEDAA_PAIRS} = 0;
    $this->{_UNIPROT_REF} = undef;
    $this->{_STAT} = undef;
    $this->{_PDB_FILE_DIR} = undef;
    bless $this, $class;
    $this->process();
    return $this;
}

sub process {
    my $this = shift;
    my ( $help, $options );
    unless( @ARGV ) { die $this->help_text(); }
    $options = GetOptions (
        'maX-3d-dis=i'  => \$this->{_MAX_3D_DIS},
        'min-seq-dis=i' => \$this->{_MIN_SEQ_DIS},
        'output-dir=s'  => \$this->{_OUTPUT_DIR},
        'uniprot-id=s'  => \$this->{_UNIPROT_ID},
        'pdb-file-dir=s' => \$this->{_PDB_FILE_DIR},
        'help' => \$help,
    );
    if ( $help ) { print STDERR help_text(); exit 0; }
    unless( $options ) { die $this->help_text(); }
    unless( defined $this->{_UNIPROT_ID} ) {  warn 'You must provide a Uniprot ID !', "\n"; die $this->help_text(); }
    unless( $this->{_OUTPUT_DIR} ) { warn 'You must provide a output directory ! ', "\n"; die $this->help_text(); }
    unless( -e $this->{_OUTPUT_DIR} ) { warn 'output directory is not exist  ! ', "\n"; die $this->help_text(); }
    unless( $this->{_PDB_FILE_DIR} ) {  warn 'You must provide a PDB file directory ! ', "\n"; die $this->help_text(); }
    unless( -e $this->{_PDB_FILE_DIR} ) { warn 'PDB file directory is not exist  ! ', "\n"; die $this->help_text(); }
    #### processing ####
    # This can be used if only want to write out pairs when one is in a Uniprot-annotated domain
    # Default is to write out every pair that is within $MaxDistance 
    # angstroms (provided they are > $PrimarySequenceDistance
    # amino acids away in the primary sequence)
    $this->{_UNIPROT_REF} = TGI::Mutpro::Preprocess::Uniprot->new( $this->{_UNIPROT_ID} );
    my $Dir = "$this->{_OUTPUT_DIR}/proximityFiles";
    my $ProximityFile = "$Dir/inProgress/$this->{_UNIPROT_ID}.ProximityFile.csv";
    # get the linkage information between PDBs if one PDB includes two or more Uniprot 
    # IDs, it should not be removed and also, sometimes, two Uniprot IDs locate in two
    # similar molecules
    my $hugoUniprot = "$this->{_OUTPUT_DIR}/hugo.uniprot.pdb.csv";
    my $linkage = $this->getLinkageInfo( $hugoUniprot );
    # Make proximity file to a temporary directory so current 
    # file can be used until this is finished 
    $this->writeProximityFile( $ProximityFile, $linkage );
    # Write a file that says if the amino acid sequence in Uniprot
    # is consistent with the sequence in the PDB structure(s)
    my $PdbCoordinateFile = "$Dir/pdbCoordinateFiles/$this->{_UNIPROT_ID}.coord";
    $this->checkOffsets($ProximityFile, $PdbCoordinateFile);
    # Now move the file from the $dir/inProgress subdirectory
    # to the root dir
    move( $ProximityFile, "$Dir/$this->{_UNIPROT_ID}.ProximityFile.csv" );

    return 1;
}

## Get proteins involved multiple uniprots ##
sub getLinkageInfo {
    my ( $this, $hugof, ) = @_;
    my $hugofh = new FileHandle;
    unless( $hugofh->open( $hugof ) ) { die "Could not open hugo uniprot file !\n" };
    my ( %multiUn, %temph, );
    foreach ( $hugofh->getlines ) {
        chomp; my ( undef, $uniprotId, $pdb, ) = split /\t/;
        # Only use Uniprot IDs with PDB structures
        next if ( $pdb eq "N/A" || $uniprotId !~ /\w+/ );
        map{ if ( (defined $temph{$_}) and ($temph{$_} ne $uniprotId) ) { $multiUn{$_} = 1; } else { $temph{$_} = $uniprotId; } } split /\s+/, $pdb;
    }
    return \%multiUn;
}

sub writeProximityFile {
    my ( $this, $file, $ulink, ) = @_;
    # $ulink linkage infor of unirpot IDs
    my $fh = new FileHandle;
    unless( $fh->open( ">$file" ) ) { die "Could not open proximity file to write !\n" };
    my ( $uniprotDomainRef,
         $pdbRef, %pdbIds, 
         %allOffsets,
         $structureRef, $peptideRef, $chainToUniprotIdRef, 
         $uniprotChain,
         $otherChainOffset, 
         $residuePositionsRef,
         $residuePosition,  
         $uniprotAminoAcidRef,
	 $otherChainUniprotId,
         $allAaObjRef, 
         $skip, 
         $position,  
         $distanceBetweenResidues, 
         $aaObjRef,
         $otherDomainRef, 
         $uniprotChainOffset,
         $uniprotAaName, 
         $otherAaName, 
         $correctedPosition, 
         $uniprotIdToDomainsRef, 
         $hugoGeneRef, $hugoId, );
    # Get Uniprot-defined domains for $this->{_UNIPROT_ID}
    ### 121105  Don't make this dependent on a specific type of annotation.
    #           Keep distances of all pairs even if the two amino acids are 
    #           not within annotated region
    #           Should ignore amino acids that would be found using the primary 
    #           sequence-based proximity analysis
    $uniprotDomainRef = uniprotDomains( $this->{_UNIPROT_ID} ) if ( $this->{_RESTRICTEDAA_PAIRS} );
    # Get all PDB structures
    $pdbRef = $this->{_UNIPROT_REF}->annotations("PDB");
    %pdbIds = ();
    if ( !defined $pdbRef || scalar(@{$pdbRef}) == 0 ) { carp "Did not get pdb IDs for $this->{_UNIPROT_ID} \n"; return; }
    # Note: new added function
    # Filtering some pdb files here to avoid unnecessary heavy load from CPU and Memory
    # Found this problem by testing all uniprot IDs initiation
    my $pdbfilterRef = $this->filteringPdb( $pdbRef, $ulink );
    map{  print STDERR "$_\n"; $pdbIds{$1} = 1 if ( $_ =~ /^(\w+)\;/ ); } @{$pdbfilterRef};
    # Download and parse PDB files
    foreach my $pdbId (keys %pdbIds) {	
	%allOffsets = ();
        #$structureRef = TGI::Mutpro::Preprocess::PdbStructure->new( $pdbId );
	$structureRef = TGI::Mutpro::Preprocess::PdbStructure->new( $pdbId, $this->{_PDB_FILE_DIR} );
        ## don't need this part when only one model 
        ## be picked up
        # abandon the pdb files with too many NUMMDL
        # >10 
	# Get Peptide objects to describe crystal structure
	$peptideRef = $structureRef->makePeptides();
	# Get chain representing given Uniprot ID.
        # Choose the chain that is the longest.
	$chainToUniprotIdRef = $structureRef->chainToUniprotId();
        $uniprotChain = undef; 
        my $chainLength = 0;
	foreach my $chain ( keys %{$chainToUniprotIdRef} ) {
            print STDERR $chain."\n";
	    next if ( $$chainToUniprotIdRef{$chain} ne $this->{_UNIPROT_ID} );
	    my ( $chainStart, $chainStop, ) = $structureRef->chainStartStop( $chain );
	    if ( $chainStop - $chainStart + 1 > $chainLength ) { 
		$uniprotChain = $chain;
                print STDERR "$pdbId\t$uniprotChain\t";
		$chainLength = $chainStop - $chainStart + 1; 
                print STDERR $chainLength."\n";
	    }
	}
	unless ( defined $uniprotChain ) {
	    print $fh "WARNING: Did not get chain for '$this->{_UNIPROT_ID}' in '$pdbId'.";
            print $fh "  Skipping structure\n";
	    next; 
	}
	#  120905  Don't tie this to Uniprot annotation
	# Get all domains for all of the Uniprot IDs in this structure
	print STDERR "RestrictAminoAcidPairs: $this->{_RESTRICTEDAA_PAIRS}\n"; 
	if ( $this->{_RESTRICTEDAA_PAIRS} ) { $uniprotIdToDomainsRef = getDomainsForAllUniprotIds( $chainToUniprotIdRef ); }
	# Get all offsets needed to convert crystal coordinates 
        # to Uniprot coordinates
	# Add 'offset' to crystal coordinate to get Uniprot coordinate
        map{
            my $offset = $structureRef->offset($_);
            $offset = "N/A" if ( !defined $offset || $offset !~ /\-?\d+$/ );
            print STDERR "$_\t offset: $offset\n";
            $allOffsets{$_} = $offset;
        } keys %{$chainToUniprotIdRef};
	# Get offset needed to convert the crystal coordinates to Uniprot coordinates
        # for the chain corresponding to $UniprotId
	$uniprotChainOffset = $allOffsets{$uniprotChain};
        print STDERR "uniprotChain:  $uniprotChain\t  uniprotChainOffset: $uniprotChainOffset\n";
	# Get position numbers (in crystal coordinates) of all residues in the peptide 
        # chain resolved in the structure
	unless ( defined $$peptideRef{$uniprotChain} ) {
	    print STDERR "\$\$peptideRef{\$uniprotChain} not defined for \$uniprotChain = $uniprotChain.";
            print STDERR "  \$UniprotId = '$this->{_UNIPROT_ID}' in '$pdbId'. Skipping structure\n";
	    next; 
	}
	$residuePositionsRef = $$peptideRef{$uniprotChain}->aminoAcidPositionNumbers();
	# Go through every position and see if it is close to an annotated domain 
        # (but not in that domain)
	# or if it is close to another peptide chain in the crystal that is a different 
        # protein that '$UniprotId'
	###
	# Updated 120905.  Record any pair of amino acids that are within $MaxDistance angstroms, 
        #                  but have amino acid positions > $PrimarySequenceDistance away
	foreach $residuePosition ( @{$residuePositionsRef} ) {
            print STDERR "residuePosition: $residuePosition\n";
	    # Get AminoAcid object for residue in chain '$uniprotChain', 
            # at position $position
	    $uniprotAminoAcidRef = $$peptideRef{$uniprotChain}->getAminoAcidObject( $residuePosition );
	    $uniprotAaName = $$uniprotAminoAcidRef->name();
            #      120905  Don't tie this to Uniprot annotation
	    # See if this is in an annotated Uniprot domain.  
            # If so, write it out.
	    if ( $this->{_RESTRICTEDAA_PAIRS} ) {
                print STDERR "RestrictAminoAcidPairs\n";
		if ( defined $$uniprotDomainRef{$residuePosition+$uniprotChainOffset} ) {
		    foreach my $domain ( keys %{$$uniprotDomainRef{$residuePosition + $uniprotChainOffset}} ) {
			print $fh "$this->{_UNIPROT_ID}\t[$uniprotChain]\t$residuePosition\t$uniprotChainOffset\t",
                        "$uniprotAaName\t$this->{_UNIPROT_ID}\t[$uniprotChain]\t$residuePosition\t",
                        "$uniprotChainOffset\t$uniprotAaName\t$domain\t0\t$pdbId\n";
		    }
		}
	    }
	    # Now compare this amino acid to all other amino acids in all of the peptide 
            # chain(s) in the crystal
	    foreach my $chain ( keys %{$peptideRef} ) {
		# Get the UniprotId of this peptide chain
		$otherChainUniprotId = $$chainToUniprotIdRef{$chain};
		#  Updated 121105.  Following is not necessary if not 
                #  restricting pairs written out
		#  Get the domains of $otherChainUniprotId 
		if ( $this->{_RESTRICTEDAA_PAIRS} ) { $otherDomainRef = $$uniprotIdToDomainsRef{ $otherChainUniprotId }; }
		# Get the offset needed to convert crystal coordinates of this 
                # peptide chain to Uniprot coordinates 
		$otherChainOffset = $allOffsets{$chain};
		$allAaObjRef = $$peptideRef{$chain}->getAllAminoAcidObjects();
                ## remove the positions with insertion code
                my @tmp_array_positions = grep{ /\d+$/ } keys %{$allAaObjRef}; 
		foreach $position ( sort {$a<=>$b} @tmp_array_positions ) {
                    if ( (defined $otherChainOffset) and ($otherChainOffset eq "N/A") ) { 
                        $correctedPosition = $position;
                    } else { 
                        if ( defined $otherChainOffset ) { $correctedPosition = $position + $otherChainOffset;} 
                    };
		    # Skip if the amino acid at '$position' of peptide chain '$chain' 
                    # is not close to the amino acid at '$residuePosition' 
                    # of peptide chain '$uniprotChain'
		    $aaObjRef = $$peptideRef{$chain}->getAminoAcidObject($position);
		    $distanceBetweenResidues = $$aaObjRef->minDistance($uniprotAminoAcidRef);
		    if ( $distanceBetweenResidues > $this->{_MAX_3D_DIS} ) { next; }
		    # Also skip if the two amino acids are in the same chain and 
                    # within <= $PrimarySequenceDistance
		    # residues of each other
		    # If two amino acids are close to each other in the primary sequence, 
                    # don't record them.
		    # They will be detected by the proximity analysis in other application
		    next if ( $chain eq $uniprotChain && abs($position - $residuePosition) <= $this->{_MIN_SEQ_DIS} );
		    $otherAaName = $$aaObjRef->name();
                    unless( defined $otherChainUniprotId ){ $otherChainUniprotId = "N/A"; };
                    unless( defined $otherChainOffset )   { $otherChainOffset    = "N/A"; };
		    if ( ! $this->{_RESTRICTEDAA_PAIRS} ) { $fh->print( "$this->{_UNIPROT_ID}\t[$uniprotChain]\t$residuePosition\t$uniprotChainOffset\t$uniprotAaName\t$otherChainUniprotId\t[$chain]\t$position\t$otherChainOffset\t$otherAaName\t$distanceBetweenResidues\t$pdbId\n" ); }
		    ##### This is just to restrict what is written out to pairs in which 
                    ##### one of the residues is in an annotated domain
		    if ( $this->{_RESTRICTEDAA_PAIRS} ) {
			# OK. The amino acid at '$residuePosition' of peptide chain '$uniprotChain' 
                        # is close to the amino acid 
			# at $position of $chain.  If '$chain' and '$uniprotChain' 
                        # represent different proteins, then
			# print it out.  This is an interaction site between different proteins
			# It doesn't matter if there is an annotated domain at $position 
                        # of $chain, but print it out if there is  
			if ( $otherChainUniprotId ne $this->{_UNIPROT_ID} ) {
			    # Initialize to no annoated domains at $position
			    my @otherChainDomains = ();
                            push @otherChainDomains, "-";
			    if ( defined $$otherDomainRef{$correctedPosition} ) { @otherChainDomains = keys %{$$otherDomainRef{$correctedPosition}}; }
			    foreach ( @otherChainDomains ) { $fh->print( "$this->{_UNIPROT_ID}\t[$uniprotChain]\t$residuePosition\t$uniprotChainOffset\t$uniprotAaName\t$otherChainUniprotId\t[$chain]\t$position\t$otherChainOffset\t$otherAaName\t$_\t$distanceBetweenResidues\t$pdbId\n"); }
                            next;
			}
			# If we are here, the two chains represent the same protein
                        # (or the two chains are the same)
			# Only print out if '$position' is in an annotated domain 
			# AND '$residuePosition' is not in the same domain 
                        # (since that domain has already been noted)
			# Skip if this is not an annotated domain in $UniprotId 
			next if ( !defined $$otherDomainRef{$correctedPosition} );
			foreach my $domain ( keys %{$$otherDomainRef{$correctedPosition}} ) { 
			    # Skip if the domain is the same as 
			    next if ( defined $$uniprotDomainRef{$residuePosition+$uniprotChainOffset} && defined $$uniprotDomainRef{$residuePosition+$uniprotChainOffset}{$domain} );
			    $fh->print( "$this->{_UNIPROT_ID}\t[$uniprotChain]\t$residuePosition\t$uniprotChainOffset\t$uniprotAaName\t$otherChainUniprotId\t[$chain]\t$position\t$otherChainOffset\t$otherAaName\t$domain\t$distanceBetweenResidues\t$pdbId\n" );
			}
		    }
                }
            }
        }
    }
    return 1;
}

sub getDomainsForAllUniprotIds {
    # Input: ref to hash with key = chain;
    #        value = Uniprot ID
    # Return: ref to hash with key = Uniprot ID; 
    #        value ref to hash of domains
    my ( $this, $chainToUniprotIdRef, ) = @_;
    my ( $uniprotId, %uniprotIdToDomains, $uniprotDomainRef, );
    foreach ( keys %{$chainToUniprotIdRef} ) {
	$uniprotId = $$chainToUniprotIdRef{$_};
	if ( !defined $uniprotId ) { next; }
	$uniprotDomainRef = $this->uniprotDomains($uniprotId);
	$uniprotIdToDomains{$uniprotId} = $uniprotDomainRef;
    }
    return \%uniprotIdToDomains;
}

sub uniprotDomains {
    # Input: Uniprot ID
    # Return: ref to hash '$uniprotDomains{$position}{"$key: $description"}'
    my ( $this, $uniprotId, ) = @_;
    my ( %uniprotDomains, $start, $stop, $key, $description, $position, );  
    my $uniprotRef = TGI::Mutpro::Preprocess::Uniprot->new( $uniprotId ); 
    # Check to see if $uniprotId returned a valid Uniprot record
    my $uniprotRecord = $uniprotRef->entireRecord();
    return \%uniprotDomains unless ( defined $uniprotRecord );
    my @recordLines = split /\n/, $uniprotRecord;
    if ( !defined $uniprotRecord || scalar(@recordLines) <= 10 ) {  return \%uniprotDomains; }
    # Get all Uniprot-defined domains.
    # Ref to array from 'push @domains, "$key\t($dmStart, $dmStop)\t$desc";'
    # Need length of protein
    my $proteinLength = length( $uniprotRef->sequence() );
    my $domainRef = $uniprotRef->domains( 1, $proteinLength );
    foreach my $entry ( @{$domainRef} ) {
	if ( $entry =~ /(\w+)\s+\((\d+)\,\s+(\d+)\)\s+(.*)\.?$/ ){ ( $key, $start, $stop, $description ) = ($1, $2, $3, $4);
	} else { print STDERR "WARNING: Could not parse domain description for '$uniprotId': '$entry'\n"; }
	if ( $start > $stop) { print STDERR "WARNING: Error parsing domain for '$uniprotId'. Start ($start) > Stop ($stop) in '$entry'\n"; }
	foreach $position ( $start..$stop ) { $uniprotDomains{$position}{"$key: $description"} = 1; }
    }
    return \%uniprotDomains;
}

sub checkOffsets {
    my ( $this, $proximityFile, $coordFile, ) = @_;
    my ( $line, 
         $uniprotA,
         $positionA, 
         $offsetA, 
         $aminoAcidA, 
         $uniprotB, 
         $positionB, 
         $offsetB, 
         $aminoAcidB, 
         $pdbId,
	 $uniprot, 
         $uniprotRef, 
         $uniprotSequenceRef, 
         $position, 
         %pdbUniprotPosition,  );
    my $profh = new FileHandle;
    unless( $profh->open( "< $proximityFile" ) ) {  die "Could not open proximity file $proximityFile to read !\n"  };
    my @entireFile = <$profh>;
    $profh->close();
    my $coorfh = new FileHandle;
    unless( $coorfh->open( "> $coordFile" ) ) {  die "Could not open coordinate file $coordFile to write !\n" };
    foreach $line ( @entireFile ) {
	chomp $line;
	next if ( $line =~ /WARNING/ );
	( $uniprotA, undef, $positionA, $offsetA, $aminoAcidA, $uniprotB, undef, $positionB, $offsetB, $aminoAcidB ) = split /\t/, $line;
	if ( $line =~ /(\S+)\s*$/ ) { $pdbId = $1; }
        # print STDERR "Unexpected format for \$uniprotA ($uniprotA) in $line.  Skipping. \n"; }
	next if ( $uniprotA !~ /^\w+$/ ); 
	next if ( $uniprotB !~ /^\w+$/ || $offsetA !~ /^-?\d+$/ || $offsetB !~ /^-?\d+$/ || $positionA !~ /^-?\d+$/ || $positionB !~ /^-?\d+$/ );
	$aminoAcidA = TGI::Mutpro::Preprocess::PdbStructure::convertAA( $aminoAcidA );
	$aminoAcidB = TGI::Mutpro::Preprocess::PdbStructure::convertAA( $aminoAcidB );
	next if ( !defined $aminoAcidA || !defined $aminoAcidB );
	if ( defined $pdbUniprotPosition{$pdbId}{$uniprotA}{$positionA+$offsetA} && $pdbUniprotPosition{$pdbId}{$uniprotA}{$positionA+$offsetA} ne $aminoAcidA ) {
	    print $coorfh "Inconsistent amino acids for $uniprotA position $positionA+$offsetA in $pdbId: '$pdbUniprotPosition{$pdbId}{$uniprotA}{$positionA+$offsetA}' and $aminoAcidA \n";
	}
	$pdbUniprotPosition{$pdbId}{$uniprotA}{$positionA+$offsetA} = $aminoAcidA;
	if ( defined $pdbUniprotPosition{$pdbId}{$uniprotB}{$positionB+$offsetB} && $pdbUniprotPosition{$pdbId}{$uniprotB}{$positionB+$offsetB} ne $aminoAcidB ) {
	    print $coorfh "Inconsistent amino acids for $uniprotB position $positionB+$offsetB in $pdbId: '$pdbUniprotPosition{$pdbId}{$uniprotB}{$positionB+$offsetB}' and $aminoAcidB \n";
	}
	$pdbUniprotPosition{$pdbId}{$uniprotB}{$positionB+$offsetB} = $aminoAcidB;
    }
    my %pdbUniprotErrorCount;
    foreach $pdbId ( keys %pdbUniprotPosition ) {
	foreach $uniprot ( keys %{$pdbUniprotPosition{$pdbId}} ) {
	    $uniprotRef = TGI::Mutpro::Preprocess::Uniprot->new($uniprot);
	    next if ( !defined $uniprotRef );
	    $uniprotSequenceRef = $this->getUniprotSeq( $uniprot );
	    $pdbUniprotErrorCount{$pdbId}{$uniprot} = 0;
	    foreach $position ( sort {$a<=>$b} keys %{$pdbUniprotPosition{$pdbId}{$uniprot}} ) {
		if ( !defined $$uniprotSequenceRef{$position} || $$uniprotSequenceRef{$position} ne $pdbUniprotPosition{$pdbId}{$uniprot}{$position} ) {
		    $pdbUniprotErrorCount{$pdbId}{$uniprot}++;
		}
	    }
	}
    }
    foreach $pdbId ( keys %pdbUniprotErrorCount ) {
	foreach $uniprot ( keys %{$pdbUniprotErrorCount{$pdbId}} ) {
	    print $coorfh "$pdbId \t $uniprot \t errors: $pdbUniprotErrorCount{$pdbId}{$uniprot} \t total: ";
	    print $coorfh scalar(keys %{$pdbUniprotPosition{$pdbId}{$uniprot}}), "\t";
	    my $fraction = $pdbUniprotErrorCount{$pdbId}{$uniprot}/scalar(keys %{$pdbUniprotPosition{$pdbId}{$uniprot}});
	    if ( $fraction != 0 && $fraction != 1 ) {
		$fraction += 0.005;
		if ( $fraction =~ /(0\.\d{2})/ ) { $fraction = $1; }
	    }
	    print $coorfh "$fraction\n";
	}
    }
    $coorfh->close();

    return 1;
}
		
# Extract uniprot sequence
sub getUniprotSeq {
    my ( $this, $uniprot, ) = @_;
    my %seq;
    my $uniprotRef = TGI::Mutpro::Preprocess::Uniprot->new($uniprot);
    my $sequence = $uniprotRef->sequence();
    if ( !defined $sequence ) { return \%seq; }
    my @seqarray = split //, $sequence;
    map{  $seq{$_+1} = $seqarray[$_];  } (0..$#seqarray);

    return \%seq;
}

# Note: throw away some pdbs  
# Filtering some pdb files here to avoid unnecessary heavy load from CPU and Memory
# Found this problem by testing all uniprot IDs initiation
sub filteringPdb {
    my ( $this, $entrysRef, $ulinks, ) = @_;
    my ( @entrysafterFiltered, $NMRs, $Xrays, $neutron, $other, %tmph, $total, );
    $NMRs = $Xrays = $neutron = $other = $total = 0;
    foreach my $a ( @{$entrysRef} ) {
        my ( $pdbtype ) = $a =~ /^\w+;\s+(.*?);\s+/;
        #print STDERR $pdbtype."\n";
        SWITCH:{
            $pdbtype eq 'X-ray'   && do { $Xrays++;   last SWITCH; };
            $pdbtype eq 'NMR'     && do { $NMRs++;    last SWITCH; };
            $pdbtype eq 'Neutron' && do { $neutron++; last SWITCH; };
            $other++;
        }
    }
    ## new added in order to retrieve more PDBs
    # date: 01222014
    $total = $NMRs + $Xrays + $neutron + $other;
    if ( $total < 50 ) {  map{ push(@entrysafterFiltered, $_); } @{$entrysRef}; return \@entrysafterFiltered; }
    # only Neutron and X-ray
    if ( ($Xrays > 0) || ($neutron > 0) ) {
        foreach my $a ( @{$entrysRef} ) {
            my ( $pdbtype, $tresolution, $chaind, ) = $a =~ /^\w+;\s+(.*?);\s+(.*?);\s+(.*?)\./;
            next unless ( $tresolution =~ /A$/ );
            my ( $resolution ) = $tresolution =~ /(.*?)\s+A/;
            $tmph{$chaind}{$resolution} = $a;
        }
        foreach my $d ( keys %tmph ) {
            my $mark = 0;
            foreach my $c ( sort {$a <=> $b} keys %{$tmph{$d}} ) {
                my ( $pdb ) = $tmph{$d}{$c} =~ /^(\w+);\s+/;
                # load filtered pdbs
                if ( $mark == 0 ) {
                    push( @entrysafterFiltered, $tmph{$d}{$c} );
                    $mark++;
                }elsif ( defined $ulinks->{$pdb} ) { push(@entrysafterFiltered, $tmph{$d}{$c}); }
            }
        }
    } else { map{ push(@entrysafterFiltered, $_); } @{$entrysRef}; }

    return \@entrysafterFiltered;
}

sub help_text {
    my $this = shift;
        return <<HELP

Usage: hotspot3d calpro [options]

--output-dir		Output directory of proximity files
--pdb-file-dir          PDB file directory 
--uniprot-id            Uniprot ID
--max-3d-dis            Maximum 3D distance in angstroms befor two amino acids
                        are considered 'close', default = 10
--min-seq-dis           Minimum linear distance in primary sequence. If two amino acids are <= 5 positions 
                        apart in the primary sequence, don't record them, default = 5 

--help			this message

HELP

}

1;

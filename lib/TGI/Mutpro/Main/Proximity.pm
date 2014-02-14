package TGI::Mutpro::Main::Proximity;
#
#----------------------------------
# $Authors: Beifang Niu 
# $Date: 2014-01-14 14:34:50 -0500 (Tue Jan 14 14:34:50 CST 2014) $
# $Revision:  $
# $URL: $
# $Doc: $ proximity pairs searching (main function)
#----------------------------------
#
use strict;
use warnings;

use Carp;
use Getopt::Long;
use IO::File;
use FileHandle;

sub new {
    my $class = shift;
    my $this = {};

    $this->{_MAF} = undef;
    $this->{_SKIP_SILENT} = undef;
    $this->{_MISSSENSE_ONLY} = undef;
    $this->{_DATA_DIR} = undef;
    $this->{_OUTPUT_PREFIX} = '3D_Proximity';
    $this->{_PVALUE_CUTOFF} = 0.05;
    $this->{_3D_CUTOFF} = 10;
    $this->{_1D_CUTOFF} = 20;
    $this->{_STAT} = undef;

    bless $this, $class;
    $this->process();

    return $this;
}

sub process {
    my $this = shift;
    my ( $help, $options );
    unless( @ARGV ) { die $this->help_text(); }
    $options = GetOptions (
        'maf-file=s' => \$this->{_MAF},
        'data-dir=s'    => \$this->{_DATA_DIR},
        'output-prefix=s' => \$this->{_OUTPUT_PREFIX},
        'skip-silent' => \$this->{_SKIP_SILENT},
        'missense-only' => \$this->{_MISSSENSE_ONLY},
        'p-value=f' => \$this->{_PVALUE_CUTOFF},
        '3d-dis=i' => \$this->{_3D_CUTOFF},
        'linear-dis=i' => \$this->{_1D_CUTOFF},
        'help' => \$help,
    );
    if ( $help ) { print STDERR help_text(); exit 0; }
    unless( $options ) { die $this->help_text(); }
    unless( $this->{_DATA_DIR} ) { warn 'You must provide a output directory ! ', "\n"; die help_text(); }
    unless( -d $this->{_DATA_DIR} ) { warn 'You must provide a valid data directory ! ', "\n"; die help_text(); }
    my $uniprot_file = "$this->{_DATA_DIR}\/hugo.uniprot.pdb.transcript.csv";
    my $prior_dir = "$this->{_DATA_DIR}\/prioritization";
    unless( -d $prior_dir ) { die "the directory $prior_dir is not exist ! \n"; };
    my @t = qw( num_muts
                num_missense
                num_silent
                num_with_uniprot
                num_unexpect_format
                num_expect_format
                num_trans 
                num_uniprot_involved
                num_trans_with_uniprot
                num_uniprot_with_trans
                num_aa_posmatch
                num_nearmatch
                num_aa_nearmatch
                num_novel
                num_nt_novel
                proximity_close_eachother
                );
    map{ $this->{_STAT}{$_} = 0; } @t;
    my $transToUniprot = $this->getTransMaptoUniprot( $uniprot_file );
    $this->{_STAT}{'num_trans_with_uniprot'} = keys %$transToUniprot;
    my $mafHashRef = $this->parseMaf( $this->{_MAF}, $transToUniprot );


    $this->{_STAT}{'num_uniprot_involved'} = keys %$mafHashRef;
    my ($pairoutref, $cosmicref, $roiref) = $this->proximitySearching( $mafHashRef, $prior_dir );
    print STDERR "searching done...\n";
    my %filterHash;
    foreach ( @$pairoutref ) {
        chomp($_);
        my @t = split /\t/;
        my $geneOne = join("\t", @t[0..8]);
        my $geneTwo = join("\t", @t[9..17]);


        print $geneOne."\t".$geneTwo."\n";

        if ( defined $filterHash{$geneOne}{$geneTwo} ) {
            $filterHash{$geneOne}{$geneTwo} .= $t[19]; 
        } elsif ( defined $filterHash{$geneTwo}{$geneOne} ) {
            $filterHash{$geneTwo}{$geneOne} .= $t[19];
        } else {
            $filterHash{$geneOne}{$geneTwo} .= $t[18] . "\t" . $t[19];
        }
    }
    # pour out proximity pairs
    my %sortedHash;
    foreach my $e (keys %filterHash) {
        foreach my $f (keys %{$filterHash{$e}}) {
            my @t = split /\t/, $filterHash{$e}{$f};
            my $lDistance = $t[0];
            my %ss = map{ ($_, 1) } split /\|/, $t[1];
            my ( %dd, $miniP, $pvaluePart );
            $pvaluePart = "";
            foreach my $d (keys %ss) {
                my @t0 = split / /, $d;
                $dd{$t0[2]}{$d} = 1;
            }
            my @t1 = sort {$a<=>$b} keys %dd;
            $miniP = $t1[0];
            foreach my $c ( @t1 ) {
                foreach my $g ( keys %{$dd{$c}} ) {
                    $pvaluePart .= $g . "|";
                }
            }
            $sortedHash{$miniP}{"$e\t$f\t$lDistance\t$pvaluePart"} = 1;
        }
    }
    ##### output #### 
    my $fh   = new FileHandle;
    die "Could not create pairwise close output file\n"  unless($fh->open(">$this->{_OUTPUT_PREFIX}.pairwise"));
    foreach my $c (sort {$a<=>$b} keys %sortedHash) {
        foreach my $d (keys %{$sortedHash{$c}}) {
            print $fh $d, "\n";
            $this->{_STAT}{'proximity_close_eachother'}++;
        }
    }
    $fh->close();
    # pour out mutations close to cosmic
    #
    die "Could not create cosmic close output file\n"  unless($fh->open(">$this->{_OUTPUT_PREFIX}.cosmic"));
    foreach (@$cosmicref) {
        print $fh $_, "\n";
    }
    $fh->close();
    # pour out mutations close to ROI
    #
    die "Could not create Region of Interest(ROI) close output file\n"  unless($fh->open(">$this->{_OUTPUT_PREFIX}.roi"));
    foreach (@$roiref) {
        print $fh $_, "\n";
    }
    $fh->close();
    
    print STDERR "total mutations: ".$this->{_STAT}{'num_muts'}."\n";
    print STDERR "expected mutations: ".$this->{_STAT}{'num_expect_format'}."\n";
    print STDERR "unexpected format mutations: ".$this->{_STAT}{'num_unexpect_format'}."\n";
    print STDERR "mutations with matched uniprot: ".$this->{_STAT}{'num_with_uniprot'}."\n";
    print STDERR "total transcripts with valid uniprot sequences : ".$this->{_STAT}{'num_trans_with_uniprot'}."\n";
    print STDERR "total transcripts in maf : ".$this->{_STAT}{'num_trans'}."\n";
    print STDERR "\n\n##################################################\n";
    #print STDERR "total mutations to be analyzed:  ".$stats{'3D'}{'tmswithUniprot'}."\n";
    print STDERR "total mutations to be analyzed:  ".$this->{_STAT}{'num_trans_with_uniprot'}."\n";
    print STDERR "total uniprots involved: ".$this->{_STAT}{'num_uniprot_involved'}."\n";
    print STDERR "\n\n##################################################\n";
    
}
# parse maf file 
sub parseMaf {
    my ( $this, $maf, $tuHashref )  = @_;
    my $fh = new FileHandle;
    unless( $fh->open($maf) ) { die "Could not open MAF format mutation file\n" };
    my $i = 0; my %fth;
    while ( my $ll = $fh->getline ) {
       if ( $ll =~ m/^Hugo_Symbol/ ) { chomp( $ll );
            %fth = map {($_, $i++)} split( /\t/, $ll );
            last;
       }
    }
    unless (    defined($fth{"Hugo_Symbol"}) 
            and defined($fth{"Chromosome"}) 
            and defined($fth{"Start_Position"})                                
            and defined($fth{"End_Position"}) 
            and defined($fth{"Reference_Allele"})                                
            and defined($fth{"Tumor_Seq_Allele1"}) 
            and defined($fth{"Tumor_Seq_Allele2"}) 
            and defined($fth{"Variant_Classification"}) 
            and defined($fth{"transcript_name"}) 
            and defined($fth{"amino_acid_change"}) ) {
        die "not a valid MAF annotation file with transcript and amino acid change !\n";
    }
    my @cols = ( $fth{"Hugo_Symbol"}, 
                 $fth{"Chromosome"}, 
                 $fth{"Start_Position"},                        
                 $fth{"End_Position"}, 
                 $fth{"Reference_Allele"}, 
                 $fth{"Tumor_Seq_Allele1"},                        
                 $fth{"Tumor_Seq_Allele2"}, 
                 $fth{"Variant_Classification"}, 
                 $fth{"transcript_name"}, 
                 $fth{"amino_acid_change"} );
    my ( %mafHash, %transHash );
    # reading file content
    while ( my $ll = $fh->getline ) {
        chomp( $ll );
        my ( $gene, $chr, $start, $end, $ref, $vart1, $vart2, $type, $trans, $aac ) = (split /\t/, $ll)[@cols];
        my $tc = join( "\t", $gene, $chr, $start, $end, $aac );
        $this->{_STAT}{'num_muts'}++;
        $transHash{ $trans } = 1;
        next if ( ($this->{_SKIP_SILENT}) and ($type eq "Silent") );
        next if ( ($this->{_MISSSENSE_ONLY}) and ($type ne "Missense_Mutation") );
        unless ( $aac =~ /p\.\w\D*\d+/ or $aac =~ /p\.\D*\d+in_frame_ins/i ) {
            print STDERR "Unexpected format for mutation: '$aac'\n";
            $this->{_STAT}{'num_unexpect_format'}++;
            next;
        }
        my ( $residue, $position );
        if ( $aac =~ /p\.(\w)\D*(\d+)/ ) { $residue = $1; $position = $2; 
        } else { $position = $aac =~ /p\.\D*(\d+)in_frame_ins/i };
        next unless( (defined $position) and ($position =~ /^\d+$/) );
        $this->{_STAT}{'num_expect_format'}++;
        next unless( defined $tuHashref->{$trans} );

        my $tmp_uniprot_id = $tuHashref->{$trans}->{'UNIPROT'};
        my $tmp_hit_bool = 0; my $tmp_uniprot_position;

        foreach my $tmp_pos ( keys %{$tuHashref->{$trans}->{'POSITION'}} ){
            if ( ($position >= $tmp_pos) and ($position <= $tuHashref->{$trans}->{'POSITION'}->{$tmp_pos}->{'TEND'}) ) {
                $tmp_uniprot_position = $position - $tmp_pos + $tuHashref->{$trans}->{'POSITION'}->{$tmp_pos}->{'UBEGIN'};
                $tmp_hit_bool = 1; 
                last;
            } 
        }
        next if ( $tmp_hit_bool == 0 );
        $mafHash{ $tmp_uniprot_id }{ $tmp_uniprot_position }{ $tc } = 1;
        $this->{_STAT}{'num_with_uniprot'}++;
    }
    $this->{_STAT}{'num_trans'} = keys %transHash;
    $fh->close();

    return \%mafHash;
}

# get mapping information 
# of transcript id to uniprot id
sub getTransMaptoUniprot {
    my ( $this, $uniprotf ) = @_;
    my $fh = new FileHandle;
    unless( $fh->open($uniprotf) ) { die "Could not open uniprot transcript mapping file\n" };
    my %transHash;
    while ( my $a = $fh->getline ) {
        chomp($a);
        my (undef, $uniprotId, undef, undef, $transcripts) = split /\t/, $a;
        next if $transcripts =~ (/N\/A/);
        map{ 
            /(\w+)\[(.*?)]/;
            my $tmp_transcript_id = $1;
            $transHash{$tmp_transcript_id}{'UNIPROT'} = $uniprotId;
            map{  /(\d+)\|(\d+)-(\d+)\|(\d+)/; 
                $transHash{$tmp_transcript_id}{'POSITION'}{$2}{'TEND'} = $4; 
                $transHash{$tmp_transcript_id}{'POSITION'}{$2}{'UBEGIN'} = $1;
                $transHash{$tmp_transcript_id}{'POSITION'}{$2}{'UEND'} = $3;
            } split /\:/, $2;
        } split /,/, $transcripts;
    }

    $fh->close();
    return \%transHash;
}

# proximity searching 
sub proximitySearching {
    my ( $this, $mafHashref, $proximityOutPrefix ) = @_;
    my ( @pairResults, @cosmicclose, @roiclose );
    my $fh = new FileHandle;
    foreach my $a ( keys %$mafHashref ) {
        my $uniprotf = "$proximityOutPrefix\/$a.ProximityFile.csv";
        next unless( -e $uniprotf ); 
        next unless( $fh->open($uniprotf) );
        while ( my $b = <$fh> ) {
            chomp($b);
            my @ta = split /\t/, $b;
            my ( $uid1, $chain1, $pdbcor1, $offset1, $residue1, $domain1, $cosmic1,
                 $uid2, $chain2, $pdbcor2, $offset2, $residue2, $domain2, $cosmic2,
                 $proximityinfor ) = @ta;
            my $uniprotcor1 = $pdbcor1 + $offset1;
            my $uniprotcor2 = $pdbcor2 + $offset2;
            my $lineardis = undef;
            if ( $uid1 eq $uid2 ) { 
                $lineardis = abs($uniprotcor1 - $uniprotcor2)
            } else { $lineardis = "N\/A"; }

            #print $a."\t".$uid2."\t".$uniprotcor1."\t".$uniprotcor2."\t".$lineardis."\n";
            if ( defined $mafHashref->{$a}->{$uniprotcor1} ) {
                if ( defined $mafHashref->{$uid2}->{$uniprotcor2} ) {
                    ## close each other
                    foreach my $c ( keys %{$mafHashref->{$a}->{$uniprotcor1}} ) {
                        foreach my $d ( keys %{$mafHashref->{$uid2}->{$uniprotcor2}} ) {
                            push( @pairResults, join("\t", $c, @ta[1,2,5,6], $d, @ta[8,9,12,13], $lineardis, $proximityinfor) );
                        }
                    }
                } else { # close to COSMIC/Domain | to do
                    foreach my $c ( keys %{$mafHashref->{$a}->{$uniprotcor1}} ) {
                        my $t_item = join("\t", $c, @ta[1,2,5,6,8,9,12,13], $lineardis, $proximityinfor);
                        if ( $domain2 !~ /N\/A/ ) { push(@roiclose, $t_item) };
                        if ( $cosmic2 !~ /N\/A/ ) { push(@cosmicclose, $t_item) };
                    }
                }
            } else {
                if ( defined $mafHashref->{$uid2}->{$uniprotcor2} ) {
                    foreach my $c ( keys %{$mafHashref->{$uid2}->{$uniprotcor2}} ) {
                        my $t_item = join("\t", $c, @ta[8,9,12,13,1,2,5,6], $lineardis, $proximityinfor);
                        if ( $domain1 !~ /N\/A/ ) { push(@roiclose, $t_item) };
                        if ( $cosmic1 !~ /N\/A/ ) { push(@cosmicclose, $t_item) };
                    }
                }
            }
        }
        $fh->close();
    }

    return (\@pairResults, \@cosmicclose, \@roiclose);
}

sub help_text{
    my $this = shift;
        return <<HELP

Usage: 3dproximity search [options]

--maf-file              Input MAF file
                        In addition to the standard version 2.3 MAF headers, there needs to be 3 columns appended.
                        These column headers in the MAF must have these names in the header in order for the tool to
                        find them: 
                                transcript_name - the transcript name, such as NM_000028 
                                amino_acid_change - the amino acid change, such as p.R290H 

--data-dir		Output directory of results
--output-prefix         Prefix of output files

--skip-silent           skip silent mutations
--missense-only         missense mutation only
--p-value               p_value cutoff(<=), default: 0.05
--3d-dis                3D distance cutoff (<=), default: 10
--linear-dis            linear distance cutoff (>=): 20 

--help			this message

HELP

}

1;

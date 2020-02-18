#!/usr/bin/env perl

# Copyright 2014  Guoguo Chen; 2015 Nagendra Kumar Goel
# Apache 2.0

use strict;
use warnings;
use Getopt::Long;

# $SIG{__WARN__} = sub { $DB::single = 1 };

my $Usage = <<'EOU';
This script creates the segments file and text file for a data directory with
new segmentation. It takes a ctm file and an "alignment" file. The ctm file
corresponds to the audio that we want to make segmentations for, and is created
by decoding the audio using existing in-domain models. The "alignment" file is
generated by the binary align-text, and is Levenshtein alignment between the
original transcript and the decoded output.

Internally, the script first tries to find silence regions (gaps in the CTM).
If a silence region is found, and the neighboring words are free of errors
according to the alignment file, then this silence region will be taken as
a split point, and new segment will be created. If the new segment we are going
to output is too long (longer than --max-seg-length), the script will split
the long segments into smaller pieces with length roughly --max-seg-length.
If you are going to use --wer-cutoff to filter out segments with high WER, make
sure you set it to a reasonable value. If the value you set is higher than the
WER from your alignment file, then most of the segments will be filtered out.

Usage: steps/cleanup/create_segments_from_ctm.pl [options] \
                              <ctm> <aligned.txt> <segments> <text>
 e.g.: steps/cleanup/create_segments_from_ctm.pl \
          train_si284_split.ctm train_si284_split.aligned.txt \
          data/train_si284_reseg/segments data/train_si284_reseg/text

Allowed options:
  --max-seg-length  : Maximum length of new segments (default = 10.0)
  --min-seg-length  : Minimum length of new segments (default = 2.0)
  --min-sil-length  : Minimum length of silence as split point (default = 0.5)
  --separator       : Separator for aligned pairs (default = ";")
  --special-symbol  : Special symbol to aligned with inserted or deleted words
                      (default = "<***>")
  --wer-cutoff      : Ignore segments with WER higher than the specified value.
                      -1 means no segment will be ignored. (default = -1)
  --use-silence-midpoints : Set to 1 if you want to use silence midpoints
                      instead of min_sil_length for silence overhang.(default 0)
  --force-correct-boundary-words : Set to zero if the segments will not be
                      required to have boundary words to be correct. Default 1
  --aligned-ctm-filename : If set, the intermediate aligned ctm
                      is saved to this file
EOU

my $max_seg_length = 10.0;
my $min_seg_length = 2.0;
my $min_sil_length = 0.5;
my $separator = ";";
my $special_symbol = "<***>";
my $wer_cutoff = -1;
my $use_silence_midpoints = 0;
my $force_correct_boundary_words = 1;
my $aligned_ctm_filename = "";
GetOptions(
  'wer-cutoff=f' => \$wer_cutoff,
  'max-seg-length=f' => \$max_seg_length,
  'min-seg-length=f' => \$min_seg_length,
  'min-sil-length=f' => \$min_sil_length,
  'use-silence-midpoints=f' => \$use_silence_midpoints,
  'force-correct-boundary-words=f' => \$force_correct_boundary_words,
  'aligned-ctm-filename=s' => \$aligned_ctm_filename,
  'separator=s'      => \$separator,
  'special-symbol=s' => \$special_symbol);

if (@ARGV != 4) {
  die $Usage;
}

my ($ctm_in, $align_in, $segments_out, $text_out) = @ARGV;

open(CI, "<$ctm_in") || die "Error: fail to open $ctm_in\n";
open(AI, "<$align_in") || die "Error: fail to open $align_in\n";
open(my $SO, ">$segments_out") || die "Error: fail to open $segments_out\n";
open(my $TO, ">$text_out") || die "Error: fail to open $text_out\n";
my $ACT= undef;
if ($aligned_ctm_filename ne "") {
    open($ACT, ">$aligned_ctm_filename");
}
# Prints the current segment to file.
sub PrintSegment {
  my ($aligned_ctm, $wav_id, $min_sil_length, $min_seg_length,
      $seg_start_index, $seg_end_index, $seg_count, $SO, $TO) = @_;

  if ($seg_start_index > $seg_end_index) {
    return -1;
  }

  # Removes the surrounding silence.
  while ($seg_start_index < scalar(@{$aligned_ctm}) &&
         $aligned_ctm->[$seg_start_index]->[0] eq "<eps>") {
    $seg_start_index += 1;
  }
  while ($seg_end_index >= 0 &&
         $aligned_ctm->[$seg_end_index]->[0] eq "<eps>") {
    $seg_end_index -= 1;
  }
  if ($seg_start_index > $seg_end_index) {
    return -1;
  }

  # Filters out segments with high WER.
  if ($wer_cutoff != -1) {
    my $num_errors = 0; my $num_words = 0;
    for (my $i = $seg_start_index; $i <= $seg_end_index; $i += 1) {
      if ($aligned_ctm->[$i]->[0] ne "<eps>") {
        $num_words += 1;
      }
      $num_errors += $aligned_ctm->[$i]->[3];
    }
    if ($num_errors / $num_words > $wer_cutoff || $num_words < 1) {
      return -1;
    }
  }

  # Works out the surrounding silence.
  my $index = $seg_start_index - 1;
  while ($index >= 0 && $aligned_ctm->[$index]->[0] eq
         "<eps>" && $aligned_ctm->[$index]->[3] == 0) {
    $index -= 1;
  }
  my $left_of_segment_has_deletion = "false";
  $left_of_segment_has_deletion = "true"
      if ($index > 0 && $aligned_ctm->[$index-1]->[0] ne "<eps>"
          && $aligned_ctm->[$index-1]->[3] == 0);

  my $pad_start_sil = ($aligned_ctm->[$seg_start_index]->[1] -
                       $aligned_ctm->[$index + 1]->[1]) / 2.0;
  if (($left_of_segment_has_deletion eq "true") || !$use_silence_midpoints) {
      if ($pad_start_sil > $min_sil_length / 2.0) {
          $pad_start_sil = $min_sil_length / 2.0;
      }
  }
  my $right_of_segment_has_deletion = "false";
  $index = $seg_end_index + 1;
  while ($index < scalar(@{$aligned_ctm}) &&
         $aligned_ctm->[$index]->[0] eq "<eps>" &&
         $aligned_ctm->[$index]->[3] == 0) {
    $index += 1;
  }
  $right_of_segment_has_deletion = "true"
      if ($index < scalar(@{$aligned_ctm})-1 && $aligned_ctm->[$index+1]->[0] ne
          "<eps>" && $aligned_ctm->[$index - 1]->[3] > 0);
  my $pad_end_sil = ($aligned_ctm->[$index - 1]->[1] +
                     $aligned_ctm->[$index - 1]->[2] -
                     $aligned_ctm->[$seg_end_index]->[1] -
                     $aligned_ctm->[$seg_end_index]->[2]) / 2.0;
  if (($right_of_segment_has_deletion eq "true") || !$use_silence_midpoints) {
      if ($pad_end_sil > $min_sil_length / 2.0) {
          $pad_end_sil = $min_sil_length / 2.0;
      }
  }

  my $seg_start = $aligned_ctm->[$seg_start_index]->[1] - $pad_start_sil;
  my $seg_end = $aligned_ctm->[$seg_end_index]->[1] +
                $aligned_ctm->[$seg_end_index]->[2] + $pad_end_sil;
  if ($seg_end - $seg_start < $min_seg_length) {
      return -1;
  }

  $seg_start = sprintf("%.2f", $seg_start);
  $seg_end = sprintf("%.2f", $seg_end);
  my $seg_id = $wav_id . "_" . sprintf("%05d", $seg_count);
  print $SO "$seg_id $wav_id $seg_start $seg_end\n";

  print $TO "$seg_id ";
  for (my $x = $seg_start_index; $x <= $seg_end_index; $x += 1) {
    if ($aligned_ctm->[$x]->[0] ne "<eps>") {
      print $TO "$aligned_ctm->[$x]->[0] ";
    }
  }
  print $TO "\n";
  return 0;
}

# Computes split point.
sub GetSplitPoint {
  my ($aligned_ctm, $seg_start_index, $seg_end_index, $max_seg_length) = @_;

  # Scan in the reversed order so we can maximize the length.
  my $split_point = $seg_start_index;
  for (my $x = $seg_end_index; $x > $seg_start_index; $x -= 1) {
    my $current_seg_length = $aligned_ctm->[$x]->[1] +
                             $aligned_ctm->[$x]->[2] -
                             $aligned_ctm->[$seg_start_index]->[1];
    if ($current_seg_length <= $max_seg_length) {
      $split_point = $x;
      last;
    }
  }
  return $split_point;
}

# Computes segment length without surrounding silence.
sub GetSegmentLengthNoSil {
  my ($aligned_ctm, $seg_start_index, $seg_end_index) = @_;
  while ($seg_start_index < scalar(@{$aligned_ctm}) &&
         $aligned_ctm->[$seg_start_index]->[0] eq "<eps>") {
    $seg_start_index += 1;
  }
  while ($seg_end_index >= 0 &&
         $aligned_ctm->[$seg_end_index]->[0] eq "<eps>") {
    $seg_end_index -= 1;
  }
  if ($seg_start_index > $seg_end_index) {
    return 0;
  }
  my $current_seg_length = $aligned_ctm->[$seg_end_index]->[1] +
                           $aligned_ctm->[$seg_end_index]->[2] -
                           $aligned_ctm->[$seg_start_index]->[1];
  return $current_seg_length;
}

# Force splits long segments.
sub SplitLongSegment {
  my ($aligned_ctm, $wav_id, $max_seg_length, $min_sil_length,
      $seg_start_index, $seg_end_index, $current_seg_count, $SO, $TO) = @_;
  # If the segment is too long, we manually split it. We make sure that the
  # resulting segments are at least ($max_seg_length / 2) seconds long.
  my $current_seg_length = $aligned_ctm->[$seg_end_index]->[1] +
                           $aligned_ctm->[$seg_end_index]->[2] -
                           $aligned_ctm->[$seg_start_index]->[1];
  my $current_seg_index = $seg_start_index;
  my $aligned_ctm_size = scalar(@{$aligned_ctm});
  while ($current_seg_length > 1.5 * $max_seg_length && $current_seg_index < $aligned_ctm_size-1) {
    my $split_point = GetSplitPoint($aligned_ctm, $current_seg_index,
                                    $seg_end_index, $max_seg_length);
    my $ans = PrintSegment($aligned_ctm, $wav_id, $min_sil_length,
                           $min_seg_length, $current_seg_index, $split_point,
                           $current_seg_count, $SO, $TO);
    $current_seg_count += 1 if ($ans != -1);
    $current_seg_index = $split_point + 1;
    $current_seg_length = $aligned_ctm->[$seg_end_index]->[1] +
                          $aligned_ctm->[$seg_end_index]->[2] -
                          $aligned_ctm->[$current_seg_index]->[1];
  }

  if ($current_seg_index eq $aligned_ctm_size-1) {
      my $ans = PrintSegment($aligned_ctm, $wav_id, $min_sil_length,
                             $min_seg_length, $current_seg_index, $current_seg_index,
                             $current_seg_count, $SO, $TO);
      $current_seg_count += 1 if ($ans != -1);
      return ($current_seg_count, $current_seg_index);
  }

  if ($current_seg_length > $max_seg_length) {
    my $split_point = GetSplitPoint($aligned_ctm, $current_seg_index,
                                    $seg_end_index,
                                    $current_seg_length / 2.0 + 0.01);
    my $ans = PrintSegment($aligned_ctm, $wav_id, $min_sil_length,
                           $min_seg_length, $current_seg_index, $split_point,
                           $current_seg_count, $SO, $TO);
    $current_seg_count += 1 if ($ans != -1);
    $current_seg_index = $split_point + 1;
  }

  my $split_point = GetSplitPoint($aligned_ctm, $current_seg_index,
                                  $seg_end_index, $max_seg_length + 0.01);
  my $ans = PrintSegment($aligned_ctm, $wav_id, $min_sil_length,
                         $min_seg_length, $current_seg_index, $split_point,
                         $current_seg_count, $SO, $TO);
  $current_seg_count += 1 if ($ans != -1);
  $current_seg_index = $split_point + 1;

  return ($current_seg_count, $current_seg_index);
}

# Processes each wav file.
sub ProcessWav {
  my ($max_seg_length, $min_seg_length, $min_sil_length, $special_symbol,
      $current_ctm, $current_align, $SO, $TO, $ACT) = @_;

  my $wav_id = $current_ctm->[0]->[0];
  my $channel_id = $current_ctm->[0]->[1];
  defined($wav_id) || die "Error: empty wav section\n";

  # First, we have to align the ctm file to the Levenshtein alignment.
  # @aligned_ctm is a list of the following:
  # [word, start_time, duration, num_errors]
  my $ctm_index = 0;
  my @aligned_ctm = ();
  foreach my $entry (@{$current_align}) {
    my $ref_word = $entry->[0];
    my $hyp_word = $entry->[1];
    if ($hyp_word eq $special_symbol) {
      # Case 1: deletion, $hyp does not correspond to a word in the ctm file.
      my $start = 0.0; my $dur = 0.0;
      if (defined($aligned_ctm[-1])) {
        $start = $aligned_ctm[-1]->[1] + $aligned_ctm[-1]->[2];
      }
      push(@aligned_ctm, [$ref_word, $start, $dur, 1]);
    } else {
      # Case 2: non-deletion, now $hyp corresponds to a word in ctm file.
      while ($current_ctm->[$ctm_index]->[4] eq "<eps>") {
        # Case 2.1: ctm contains silence at the corresponding place.
        push(@aligned_ctm, ["<eps>", $current_ctm->[$ctm_index]->[2],
                             $current_ctm->[$ctm_index]->[3], 0]);
        $ctm_index += 1;
      }
      my $ctm_word = $current_ctm->[$ctm_index]->[4];
      $hyp_word eq $ctm_word ||
        die "Error: got word $hyp_word in alignment but $ctm_word in ctm\n";
      my $start = $current_ctm->[$ctm_index]->[2];
      my $dur = $current_ctm->[$ctm_index]->[3];
      if ($ref_word ne $ctm_word) {
        if ($ref_word eq $special_symbol) {
          # Case 2.2: insertion, we propagate the duration and error to the
          #           previous one.
          if (defined($aligned_ctm[-1])) {
            $aligned_ctm[-1]->[2] += $dur;
            $aligned_ctm[-1]->[3] += 1;
          } else {
            push(@aligned_ctm, ["<eps>", $start, $dur, 1]);
          }
        } else {
          # Case 2.3: substitution.
          push(@aligned_ctm, [$ref_word, $start, $dur, 1]);
        }
      } else {
        # Case 2.4: correct.
        push(@aligned_ctm, [$ref_word, $start, $dur, 0]);
      }
      $ctm_index += 1;
    }
  }

  # Save the aligned CTM if needed
  if(defined($ACT)){
    for (my $i = 0; $i <= $#aligned_ctm; $i++) {
      print $ACT "$wav_id $channel_id $aligned_ctm[$i][1] $aligned_ctm[$i][2] ";
      print $ACT "$aligned_ctm[$i][0] $aligned_ctm[$i][3]\n";
    }
  }

  # Second, we create segments from @align_ctm, using simple greedy method.
  my $current_seg_index = 0;
  my $current_seg_count = 0;
  for (my $x = 0; $x < @aligned_ctm; $x += 1) {
    my $lcorrect = "true"; my $rcorrect = "true";
    $lcorrect = "false" if ($x > 0 && $aligned_ctm[$x - 1]->[3] > 0);
    $rcorrect = "false" if ($x < @aligned_ctm - 1 &&
                            $aligned_ctm[$x + 1]->[3] > 0);

    my $current_seg_length = GetSegmentLengthNoSil(\@aligned_ctm,
                                                   $current_seg_index, $x);

    # We split the audio, if the silence is longer than the requested silence
    # length, and if there are no alignment error around it. We also make sure
    # that segment contains actual words, instead of pure silence.
    if ($aligned_ctm[$x]->[0] eq "<eps>" &&
        $aligned_ctm[$x]->[2] >= $min_sil_length
       && (($force_correct_boundary_words && $lcorrect eq "true" &&
            $rcorrect eq "true") || !$force_correct_boundary_words)) {
      if ($current_seg_length <= $max_seg_length &&
          $current_seg_length >= $min_seg_length) {
        my $ans = PrintSegment(\@aligned_ctm, $wav_id, $min_sil_length,
                               $min_seg_length, $current_seg_index, $x,
                               $current_seg_count, $SO, $TO);
        $current_seg_count += 1 if ($ans != -1);
        $current_seg_index = $x + 1;
      } elsif ($current_seg_length > $max_seg_length) {
        ($current_seg_count, $current_seg_index)
          = SplitLongSegment(\@aligned_ctm, $wav_id, $max_seg_length,
                             $min_sil_length, $current_seg_index, $x,
                             $current_seg_count, $SO, $TO);
      }
    }
  }

  # Last segment.
  if ($current_seg_index <= @aligned_ctm - 1) {
    SplitLongSegment(\@aligned_ctm, $wav_id, $max_seg_length, $min_sil_length,
                     $current_seg_index, @aligned_ctm - 1,
                     $current_seg_count, $SO, $TO);
  }
}

# Insert <eps> as silence so the down stream process will be easier. Example:
#
# Input ctm:
# 011 A 3.39 0.23 SELL
# 011 A 3.62 0.18 OFF
# 011 A 3.83 0.45 ASSETS
#
# Output ctm:
# 011 A 3.39 0.23 SELL
# 011 A 3.62 0.18 OFF
# 011 A 3.80 0.03 <eps>
# 011 A 3.83 0.45 ASSETS
sub InsertSilence {
  my ($ctm_in, $ctm_out) = @_;
  for (my $x = 1; $x < @{$ctm_in}; $x += 1) {
    push(@{$ctm_out}, $ctm_in->[$x - 1]);

    my $new_start = sprintf("%.2f",
                            $ctm_in->[$x - 1]->[2] + $ctm_in->[$x - 1]->[3]);
    if ($new_start < $ctm_in->[$x]->[2]) {
      my $new_dur = sprintf("%.2f", $ctm_in->[$x]->[2] - $new_start);
      push(@{$ctm_out}, [$ctm_in->[$x - 1]->[0], $ctm_in->[$x - 1]->[1],
                         $new_start, $new_dur, "<eps>"]);
    }
  }
  push(@{$ctm_out}, $ctm_in->[@{$ctm_in} - 1]);
}

# Reads the alignment.
my %aligned = ();
while (<AI>) {
  chomp;
  my @col = split;
  @col >= 2 || die "Error: bad line $_\n";
  my $wav = shift @col;
  if ( (@col + 0) % 3 != 2) {
    die "Bad line in align-text output (unexpected number of fields): $_";
  }
  my @pairs = ();

  for (my $x = 0; $x * 3 + 2 < @col; $x++) {
    my $first_word = $col[$x * 3];
    my $second_word = $col[$x * 3 + 1];
    if ($x * 3 + 2 < @col) {
      if ($col[$x * 3 + 2] ne $separator) {
        die "Bad line in align-text output (expected separator '$separator'): $_";
      }
    }
    # the [ ] expression returns a reference to a new anonymous array.
    push(@pairs, [ $first_word, $second_word ]);
  }
  ! defined($aligned{$wav}) || die "Error: $wav has already been processed\n";
  $aligned{$wav} = \@pairs;
}

# Reads the ctm file and creates the segmentation.
my $previous_wav_id = "";
my $previous_channel_id = "";
my @current_wav = ();
while (<CI>) {
  chomp;
  my @col = split;
  @col >= 5 || die "Error: bad line $_\n";
  if ($previous_wav_id eq $col[0] && $previous_channel_id eq $col[1]) {
    push(@current_wav, \@col);
  } else {
    if (@current_wav > 0) {
      defined($aligned{$previous_wav_id}) ||
        die "Error: no alignment info for $previous_wav_id\n";
      my @current_wav_silence = ();
      InsertSilence(\@current_wav, \@current_wav_silence);
      ProcessWav($max_seg_length, $min_seg_length, $min_sil_length,
                 $special_symbol, \@current_wav_silence,
                 $aligned{$previous_wav_id}, $SO, $TO, $ACT);
    }
    @current_wav = ();
    push(@current_wav, \@col);
    $previous_wav_id = $col[0];
    $previous_channel_id = $col[1];
  }
}

# The last wav file.
if (@current_wav > 0) {
  defined($aligned{$previous_wav_id}) ||
    die "Error: no alignment info for $previous_wav_id\n";
  my @current_wav_silence = ();
  InsertSilence(\@current_wav, \@current_wav_silence);
  ProcessWav($max_seg_length, $min_seg_length, $min_sil_length, $special_symbol,
             \@current_wav_silence, $aligned{$previous_wav_id}, $SO, $TO, $ACT);
}

close(CI);
close(AI);
close($SO);
close($TO);
close($ACT) if defined($ACT);
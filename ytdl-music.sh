#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

# todo: remove year metadata; ytdl grabs from upload-date which isn't the release date
# todo: add flag to clear ytdl-download-history.list

# +-------------------------------------------------------------------------+ #
# |                              Documentation                              | #
# +-------------------------------------------------------------------------+ #

#                                 dependencies                                #
# 
# yt-dlp: Downloading songs from youtube
# ffmpeg: For transcoding down to 64kbps opus, yt-dlp also uses it
# ffprobe: Usually comes with ffmpeg. used to analyze cover image filetype.
#          Might be able to remove dep.
# image-magick: For manipulating and compressing the cover image
# kid3-cli: For adding a cover image to the final opus file

#                                 yt-dlp args                                 #
#
# --format: Prefer Opus '250' first (64kbps), then fallback to whatever is best, 
# with video last
# --no-playlist: is ignored when the URL is only a playlist. This is for when
# a url is a song+playlist url in one. This gives me the option to download
# single tracks without further intervention
# --extract-audio: only runs when video is the last resort
# --audio-format: we desire opus. Skips transcoding when already opus
# --add-metadata: attempts to fill out the id3 tags appropriately
# --embed-thumbnail: the thumbnails for music are square, but yt-dlp graps 
# widescreen which is unideal.

#                                 ffmpeg args                                 #
# 
# -y: automatically say yes to existing file override
# -v: ffmpeg is too noisy. only errors
# -i: input
# -an: no audio in output
# -vcodec: copy the image metadata

#                                    Notes                                    #
# 
# stdout: Note that program calls within functions have their stdout silenced
#         implicitly.
# Opus & Covers: ffmpeg does not keep cover images through opus conversions,
#         so we must dump and inject it into the final file. Incidentally, 
#         yt-dlp seems to Download widescreen cover images, which are incorrect.
#         So we use imagemagick to crop and downscale.

# +-------------------------------------------------------------------------+ #
# |                               Global Vars                               | #
# +-------------------------------------------------------------------------+ #

COLOR_RESET="\033[0m"
COLOR_YELLOW="\033[33m"
COLOR_BRIGHT_YELLOW="\033[93m"
COLOR_BRIGHT_MAGENTA="\033[95m"
COLOR_BRIGHT_RED="\033[91m"
COLOR_BRIGHT_GREEN="\033[92m"

WORKING_DIR="$HOME/Downloads/_yt-dlp"
DOWNLOAD_DIR="$HOME/Downloads/yt-dlp"
YTDL=$(command -v yt-dlp || command -v youtube-dl)
error_tracker=()

# +-------------------------------------------------------------------------+ #
# |                          Bash Args Boilerplate                          | #
# +-------------------------------------------------------------------------+ #

# globals related to arg-parsing is kept here for modularity
POSITIONAL_ARGS=()
BITRATE="64k"
SKIP_YTDL=NO
VERBOSE=""
SKIP_ALBUM_ART=NO # Using "NO" for increased readability in if-statements
CUSTOM_ALBUM_COVER_OVERLAY_IMAGE=""
IS_COLLECTION=""
NO_PRUNE=""
YTDL_DOWNLOAD_HISTORY="ytdl-download-history.list.txt" # default path when not specified

show_help() {
  cat <<EOF
Usage: ytdl-music [flags] url

Passing no url enters an interactive mode in which to paste a youtube url.

How to use:
  Navigate to an album overview on yt music. Copy/Paste the playlist-specific
  url as the final argument. If you click into a specific song, the url will
  reflect both the playlist and the specific song, but will only download that
  specific song.

Options:
  -h,  --help        Show this help and exit
  -v,  --verbose     Enable verbose mode
  -s,  --skip-ytdl   Skip yt-dl and only process existing files in the working_dir
                     (helpful for stuck files, or processing existing collections)
  -sa, --skip-album-art
                     Bypass processing album-art covers (extracting, cropping,
                     injecting)
  --custom-cover-overlay
                     Specify an image to overlay on top of album-cover. Expects a
                     512x512 image with alpha-channel. (default: off)
  --collection       Specifies that the files in the working_dir are not from one
                     single album. Useful for processing collections at a time.
                     Prevents borrowing album-covers from other files.
  --no-prune         Skip the final cleanup phase of files
  --download-archive Manually specify a custom download-archive list file for yt-dl.
                     Useful for scripting when said scripts need their own download
                     tracking. (default: ytdl-download-history.list)

Requirements:
  - yt-dl (or yt-dlp)
  - ffmpeg
  - ffprobe
  - image-magick
  - kid3-cli
EOF
}

# Boilerplate Arg management https://stackoverflow.com/questions/192249/how-do-i-parse-command-line-arguments-in-bash
# flags that take no values only perform one shift, instead of two
while [[ $# -gt 0 ]]; do
  case $1 in
    -s|--skip-ytdl)
      SKIP_YTDL=YES
      shift # past argument
      ;;
    -b|--bitrate)
      BITRATE="$2"
      shift # past argument
      shift # past value
      ;;
    -sa|--skip-album-art)
      SKIP_ALBUM_ART=YES
      shift # past argument
      ;;
    --custom-cover-overlay)
      CUSTOM_ALBUM_COVER_OVERLAY_IMAGE="$2"
      shift # past argument
      shift # past value
      ;;
    --collection)
      IS_COLLECTION=YES
      shift # past argument
      ;;
    --no-prune)
      NO_PRUNE=YES
      shift # past argument
      ;;
    --download-archive)
      YTDL_DOWNLOAD_HISTORY="$2"
      shift # past argument
      shift # past value
      ;;
    --help)
      show_help
      shift # past argument
      exit 0
      ;;
    -v|--verbose)
      # todo
      VERBOSE=YES
      shift # past argument
      ;;
    -*|--*)
      echo "Unknown option $1"
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift # past argument
      ;;
  esac
done

set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

# Assign last argument as url
if [[ -n $1 ]]; then
    # echo "Last line of file specified as non-opt/last argument:"
    url="$1"
fi

# If no args passed in, interactively ask for the URL
if [ -z "$1" ] && [ "$SKIP_YTDL" = "NO" ]; then
  read -p "Enter the YT/YT-Music URL: " url
else
  url="$1"
fi

# +-------------------------------------------------------------------------+ #
# |                                  Utils                                  | #
# +-------------------------------------------------------------------------+ #

check_dependencies() {
  local DEPS=($YTDL ffmpeg ffprobe magick kid3-cli) # List of required commands
  local is_missing_deps=0 # Flag for missing deps

  for cmd in "${DEPS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Error: $cmd is not installed."
      is_missing_deps=1
    fi
  done

  # Quit if anything is missing
  if [ "$is_missing_deps" -eq 1 ]; then
    exit 1
  fi
}

# Print to terminal (uses stderr so functions can return echo's stdout)
print() {
    echo -e "$@" >&2
}

print_verbose() {
  if [ "$VERBOSE" != "YES" ]; then return; fi
  echo -e "$COLOR_YELLOW""$@""$COLOR_RESET" >&2
}

# A nicely printed report at the end
error_report() {
  if [ "${#error_tracker[@]}" -gt 0 ]; then
    print "\n$COLOR_BRIGHT_RED""There were ${#error_tracker[@]} error(s):"
  fi

  for item in "${error_tracker[@]}"; do
    print "  - $COLOR_BRIGHT_RED""$item"
  done
}

get_filesize_mb() {
  local file="$1"

  local size_bytes=$(wc -c < "$file")
  local size_mb=$(awk "BEGIN {printf \"%.1f MB\", $size_bytes / 1024 / 1024}")
  echo "$size_mb"
}

delete_file() {
  local file="$1"

  if [ "$NO_PRUNE" = "YES" ]; then
    print_verbose "Skipping Prune Step"
    return 0
  fi

  if [ -f "$file" ]; then
    print_verbose "  + rm -f $file"
    rm -f "$file"
  fi
}

verify_then_delete() {
  local original_file_filepath="$1"
  local converted_dst_filepath="$2"

  opusinfo "$converted_dst_filepath" >/dev/null 2>&1

  if [ $? -ne 0 ]; then
    print "$COLOR_BRIGHT_RED""  - Destination failed opus-check. Not deleting original""$COLOR_RESET"
    print "$COLOR_BRIGHT_RED""    src: $original_file_filepath""$COLOR_RESET"
    print "$COLOR_BRIGHT_RED""    dst: $converted_dst_filepath""$COLOR_RESET"

    error_tracker+=("opusinfo errored validating: $converted_dst_filepath")
    return 1
  fi

  local original_filesize=$(get_filesize_mb "$original_file_filepath")
  local output_filesize=$(get_filesize_mb "$converted_dst_filepath")

  print "  $COLOR_BRIGHT_YELLOW""Input Size: $original_filesize | Output Size: $output_filesize""$COLOR_RESET"

  delete_file "$original_file_filepath"
}

cleanup() {
  local original_file="$1" # $filename
  local move_src="$2" # $filepath_transcoded_tmp
  local move_dst="$3" # $filepath_final_out
  local albumart_extracted="$4" # $albumart_extracted_filename
  local albumart_cropped="$5" # $albumart_cropped_filename

  print "$COLOR_BRIGHT_YELLOW""  Cleanup""$COLOR_RESET"
  print_verbose "  + mv\n    src: $move_src\n    dst: $move_dst"

  # remove temp files (attempt regardless if files were made this session)
  delete_file "$albumart_extracted"
  delete_file "$albumart_cropped"

  # move (clobber) file into final destination
  mv "$move_src" "$move_dst"
  verify_then_delete "$original_file" "$move_dst" 
}

initialize() {
  check_dependencies

  # Create working directories
  mkdir -p "$WORKING_DIR"
  mkdir -p "$DOWNLOAD_DIR"
  cd $WORKING_DIR

  # Print debug info
  print_verbose ""
  print_verbose "yt-dl/p location: $YTDL"
  print_verbose "Positional Arguments: $POSITIONAL_ARGS"
  print_verbose "Bitrate: $BITRATE"
  print_verbose "Skip yt-dl step?: $SKIP_YTDL"
  print_verbose "Skip Album Cover Management?: $SKIP_ALBUM_ART"
  print_verbose ""
}

# +-------------------------------------------------------------------------+ #
# |                                Download                                 | #
# +-------------------------------------------------------------------------+ #

download_music() {
  local yt_url="$1" # $url

  if [ "$SKIP_YTDL" = "YES" ]; then
    print "$COLOR_BRIGHT_YELLOW""Step: Skipping yt-dlp""$COLOR_RESET""\n"
    return 0
  fi

  # Check if the url is the entire channel. This is usually too much and you
  # lose out on track-numbering since playlists are ordered in the same album
  # order on yt. 
  if [[ "$var" == *"/channel/"* ]]; then
    print "$COLOR_BRIGHT_RED""Error: The URL appears to be an entire channel and not a specific album. Track numbering isn't possible with this approach. Aborting.""$COLOR_RESET""\n"
    exit 1
  fi
  
  # Note: ytdl quality selectors don't seem to apply in our configuration
  print "$COLOR_BRIGHT_YELLOW""Step: Running yt-dlp""$COLOR_RESET""\n"
  # todo: swap out for the universal path for yt-dl/p
  # trim-filenames 245 accounts for the appending of ".ext.part" from the 255 limit
  yt-dlp \
    --format "250/bestaudio[ext=opus]/bestaudio/best" \
    --extract-audio \
    --audio-format opus \
    --add-metadata \
    --embed-thumbnail \
    --download-archive "$YTDL_DOWNLOAD_HISTORY" \
    --no-playlist \
    --trim-filenames 245 \
    --output "%(artist)s - %(album)s - %(0Dtrack_number,playlist_index)s - %(title)s.%(ext)s" \
    $yt_url

  # Abort and exit script if yt-dl fails. If the user wants to process existing files, they can
  # run the skip flag manually
  if [ $? -ne 0 ]; then
    print "$COLOR_BRIGHT_RED""Aborted early, as yt-dl failed. Rerun with -s|--skip-ytdl to process existing files in the working_dir"
    exit 1
  fi
}

# +-------------------------------------------------------------------------+ #
# |                              Album Covers                               | #
# +-------------------------------------------------------------------------+ #

probe_album_cover_ext() {
  local FALLBACK_EXT="jpg"

  # Guard
  if [ "$SKIP_ALBUM_ART" = "YES" ]; then
    print_verbose "  Setting Enabled: Skip Extract Album Covers"
    echo $FALLBACK_EXT # return for graceful handling
    return 0
  fi

  print "$COLOR_BRIGHT_YELLOW""  Probe Album Cover Extension""$COLOR_RESET"

  # Probe for file extension
  albumart_ext=$(
    ffprobe \
      -v error \
      -select_streams v:0 \
      -show_entries stream=codec_name \
      -of default=noprint_wrappers=1:nokey=1 \
      "$1"
  )
  
  if [ -z "$albumart_ext" ]; then
    print "  $COLOR_BRIGHT_RED- Failed to probe Album Cover Extension. fallback set to $FALLBACK_EXT"
  fi

  # Fallback
  albumart_ext=${albumart_ext:-$FALLBACK_EXT}

  # Return
  print_verbose "  + Album Cover Extension: $albumart_ext"
  echo "$albumart_ext"
}

extract_album_cover() {
  local input_file="$1" # $filename
  local output_file="$2" # $albumart_extracted_filename
  local fallback_file="$3" # $albumart_universal_album_filename

  # Note: this is written for .opus specifically. flacs and other formats may fail
  # todo: "${VERBOSE:+info}${VERBOSE:+"error"}" for -v line
  if [ "$SKIP_ALBUM_ART" = "YES" ]; then
    print_verbose "  + Skipping: Extract Album Cover"
    return 0
  fi

  print "$COLOR_BRIGHT_YELLOW""  Extract Album Cover""$COLOR_RESET"

  ffmpeg \
    -y \
    -v error \
    -i "$input_file" \
    -an \
    -vcodec copy \
    "$output_file" \
    >/dev/null 2>&1 # silence ffmpeg

  # Check for Failure
  if [ $? -ne 0 ]; then
    print "  $COLOR_BRIGHT_RED""- ffmpeg failed to extract album cover""$COLOR_RESET"

    # Now check for album-wide cover already exists. If so, copy it into place
    if [ -f "$fallback_file" ]; then
      print "  $COLOR_YELLOW""Using album-wide cover as alternative"
      cp "$fallback_file" "$output_file"
    fi
  fi
}

crop_album_cover() {
  # crop_album_cover <input> <output>
  # Arguments
  #   input   – filename of the input image
  #   output  – filename of the output (cropped) image
  local input="$1" # $albumart_extracted_filename
  local output="$2" # $albumart_cropped_filename

  # If skip setting is true, or if the input file is missing, then return early
  if [ "$SKIP_ALBUM_ART" = "YES" ] || [ ! -f "$input" ]; then
    print_verbose "  $COLOR_YELLOW""+ Skipping: Crop Album Cover""$COLOR_RESET"
    return 0
  fi

  print "$COLOR_BRIGHT_YELLOW""  Crop Album Cover""$COLOR_RESET"
  img_size=$(magick identify -format '%[fx:min(w,h)]' "$input")

  # Failure handling
  if [ $? -ne 0 ]; then
    print "  $COLOR_BRIGHT_RED""image-magick failed to determine image size""$COLOR_RESET"
    return 1
  fi

  magick \
    "$input" \
    -gravity center \
    -crop "${img_size}x${img_size}+0+0" \
    +repage \
    -resize 512x512 \
    "$output"

  # Failure handling
  if [ $? -ne 0 ]; then
    print "  $COLOR_BRIGHT_RED""image-magick failed to crop image""$COLOR_RESET"
    return 1
  fi
}

overlay_custom_cover_overlay() {
  # overlay_custom_cover_overlay <input>
  # This function is intended to inline replace and utilizes magick's ability
  # to do so. Only occurs if option is specified.
  # 
  # Arguments
  #   input   – filename of the input image
  local input="$1" # $albumart_cropped_filename
  local output="$input" # intentional inline replace

  # If setting is missing, or if the input file is missing, then return early
  if [ "$CUSTOM_ALBUM_COVER_OVERLAY_IMAGE" = "" ] || [ ! -f "$input" ]; then
    print_verbose "  $COLOR_YELLOW""+ Skipping: Overlaying Custom Cover Overlay""$COLOR_RESET"
    return 0
  fi

  print "$COLOR_BRIGHT_YELLOW""  Overlaying Custom Cover Overlay""$COLOR_RESET"

  # Note: Geometry isn't needed if all the images are 512x512, but this helps
  # increases compatibility for potential edgecases
  magick \
    "$input" \
    "$CUSTOM_ALBUM_COVER_OVERLAY_IMAGE" \
    -gravity Center \
    -geometry 512x512+0+0 \
    -composite \
    "$output"

  # Failure handling
  if [ $? -ne 0 ]; then
    print "  $COLOR_BRIGHT_RED""image-magick failed to overlay image""$COLOR_RESET"
    return 1
  fi
}

save_universal_cover_fallback() {
  local cover="$1"
  local universal_cover="$2" # $albumart_universal_album_filename

  if [ "$IS_COLLECTION" = "YES" ]; then
    return 0
  fi

  if [ -f "$cover" ]; then
    print_verbose "  + Setting Universal Album Cover Fallback"
    cp "$cover" "$universal_cover"
  fi
}

set_album_cover() {
  local cover="$1" # $albumart_cropped_filename
  local output="$2" # $filepath_transcoded_tmp

  # Setting cover-art for opus is notoriously difficult. kid3-cli works, ffmpeg
  # works too, but only if image is already in spec format for passin as custom
  # metadata argument.
  # 
  # Note: The fallback cover is set through a cp command (if conditions apply)
  #       before this function runs. So if the file is missing, tnere is no cover
  # 
  # BUG: when specifying a cover, current directory does not matter! The image
  #      must be in the same directory as the file being modified

  # Skip if setting enabled, or cover is missing
  if [ "$SKIP_ALBUM_ART" = "YES" ] || [ ! -f "$cover" ]; then
    print_verbose "  + Skipping: Set Album Cover"
    return 0
  fi

  print "$COLOR_BRIGHT_YELLOW""  Set Album Cover""$COLOR_RESET"
  kid3-cli \
    -c "set picture:${cover} 'Cover (front)'" \
    "$output"

  if [ $? -ne 0 ]; then
    print "  $COLOR_BRIGHT_RED""set-cover error in kid3-cli""$COLOR_RESET"
    error_tracker+=("kid3-cli errored on set-cover for: $input")
  fi
}

# +-------------------------------------------------------------------------+ #
# |                               Transcoding                               | #
# +-------------------------------------------------------------------------+ #

transcode_audio() {
  local input="$1" # $filename
  local output="$2" # $filepath_transcoded_tmp

  print "$COLOR_BRIGHT_YELLOW""  Transcode to $BITRATE Opus""$COLOR_RESET"

  ffmpeg \
    -y \
    -v error \
    -i "$input" \
    -c:a libopus \
    -b:a "$BITRATE" \
    -map_metadata 0 \
    "$output"

  if [ $? -ne 0 ]; then
    print "  $COLOR_BRIGHT_RED""- Transcode error""$COLOR_RESET"
    error_tracker+=("re-transcode to opus failed on: $input")
  fi
}

get_track_num_from_filename() {
  local filename="$1"

  # Relies on the filename output from YT-DL to be a specific format we
  # specified earlier
  track=$(echo "$filename" | awk -F' - ' '{print $3}')

  # Check specifically for "NA", which yt-dl does when not downloading from a
  # playlist. Even if the song is from an album
  if [ "$filename" = "NA" ]; then
    print "$COLOR_BRIGHT_YELLOW""  + Track Num is 'NA' from ytdl. Not setting tag"
    echo ""
    return 0
  fi

  echo "$track" # return value
}

set_track_num() {
  local file="$1"
  local track_num="$2"

  # Numeric check. Verified value only consists of 0-9 chars
  if [[ ! "$track_num" =~ ^[0-9]+$ ]]; then
    print "$COLOR_BRIGHT_YELLOW""  + Track Num are not numbers. Not setting tag"
    print "$COLOR_BRIGHT_YELLOW""    value: $track_num"
    echo ""
    return 0
  fi

  print "$COLOR_BRIGHT_YELLOW""  Set Track Number Tag: $track_num""$COLOR_RESET"
  kid3-cli \
    -c "set track $track_num" \
    "$file"
}

# +-------------------------------------------------------------------------+ #
# |                                   Main                                  | #
# +-------------------------------------------------------------------------+ #

# --- Initial Checks & Setup --- #
initialize

# --- Download Music --- #
download_music $url

# --- Iterate Over Files & Process --- #
print "$COLOR_BRIGHT_YELLOW""Step: Downsample All to $BITRATE Opus""$COLOR_RESET"

shopt -s nullglob # dont expand unmatched globs
for filename in *.opus *.mp3 *.flac *aac; do
  # Skip temp files
  if [[ "$filename" == *.tmp* ]]; then
    print_verbose "  Skipping .tmp file $filename"
    continue
  fi

  print "\n""$COLOR_BRIGHT_YELLOW""File: ""$COLOR_BRIGHT_GREEN""$filename""$COLOR_RESET"

  basename="${filename%.*}"  # removes everything after the last dot
  filepath_final_out="$DOWNLOAD_DIR/${basename}.opus"
  filepath_transcoded_tmp="$WORKING_DIR/${basename}.tmp.opus"
  albumart_ext="$(probe_album_cover_ext "$filename")" # Probe Album Cover for Extension
  albumart_extracted_filename="cover.tmp.$albumart_ext"
  albumart_cropped_filename="cover.jpg"
  albumart_universal_album_filename="album.jpg"
  track_num=$(get_track_num_from_filename "$filename") # Extract track num from filename

  extract_album_cover \
    "$filename" \
    "$albumart_extracted_filename" \
    "$albumart_universal_album_filename"

  crop_album_cover \
    "$albumart_extracted_filename" \
    "$albumart_cropped_filename"

  overlay_custom_cover_overlay \
    "$albumart_cropped_filename"

  save_universal_cover_fallback \
    "$albumart_cropped_filename" \
    "$albumart_universal_album_filename"
  
  transcode_audio \
    "$filename" \
    "$filepath_transcoded_tmp"

  set_track_num \
    "$filepath_transcoded_tmp" \
    "$track_num"

  set_album_cover \
    "$albumart_cropped_filename" \
    "$filepath_transcoded_tmp"
  
  cleanup \
    "$filename" \
    "$filepath_transcoded_tmp" \
    "$filepath_final_out" \
    "$albumart_extracted_filename" \
    "$albumart_cropped_filename"

done
shopt -u nullglob # see matching shopt above

# --- Final Cleanup --- #
rm -f "$albumart_universal_album_filename"
print "$COLOR_BRIGHT_YELLOW""\nProcess Complete""$COLOR_RESET"
error_report

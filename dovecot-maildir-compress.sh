#!/bin/bash

# 2025-09-13 @George-NG
# * Renamed the debug name and var to "dryrun" as that's more appropriate for what that is used for
# * Updated the dryrun output to be a bit more verbose about what would be done
# * Renamed the variables for the `cur` and `tmp` directories to make them more descriptive
# * Added extra arguments for displaying warnings, and for selecting depth of operation and verbosity
# * Added convenience functions for printing out messages on the screen
# * Added additional colours to the output, in use with the printing functions
# * Changed indentation throughout the script - the original was using 8 spaces (tabs), changed it
# to 4 and re-indented everything
# * Changed the "find" variable to "files_found", as it wasn't very descriptive. This allowed for
# additional checks to be added and to display additional information
# * Removed the file search based on flag in the file name. Instead, all files have their mime-type
# checked and acted on according to the selected action.
# * Added additional check for number of files found for the selected operation. This allows us to
# skip the whole section of moving the files back to `cur`, and because of that - not having to lock
# the maildir and do nothing with the lock.
# * Removed the whole section which was updating the file name to add the `Z` flag - dovecot does not
# care about these flags and this modification can cause problems with the service (check the README)
# 
# 2023-08-13 @styelz
# * Changed locking to use flock instead of maildirlock due to segfaulting issues on cpanel servers.
# * Added detection of compressed file types when decompressing
# * Changed the way tmpdir is defined 

## Originally based on:
## https://gist.github.com/cs278/1490556
## http://ivaldi.nl/blog/2011/12/06/compressed-mail-in-dovecot/

# This is from the original guide
# Find the mails you want to compress in a single maildir.
#
#     Skip files that don't have ,S=<size> in the filename.
#
# Compress the mails to tmp/
#
#     Update the compressed files' mtimes to be the same as they were in the original files (e.g. touch command)
#
# Run maildirlock <path> <timeout>. It writes PID to stdout, save it.
#
#     <path> is path to the directory containing Maildir's dovecot-uidlist (the control directory, if it's separate)
#
#     <timeout> specifies how long to wait for the lock before failing.
#
# If maildirlock grabbed the lock successfully (exit code 0) you can continue.
# For each mail you compressed:
#
#     Verify that it still exists where you last saw it.
#     If it doesn't exist, delete the compressed file. Its flags may have been changed or it may have been expunged.
#     This happens rarely, so just let the next run handle it.
#
#     If the file does exist, rename() (mv) the compressed file over the original file.
#
#         Dovecot can now read the file, but to avoid compressing it again on the next run, you'll probably want to
#         rename it again to include e.g. a "Z" flag in the file name to mark that it was compressed (e.g.
#         1223212411.M907959P17184.host,S=3271:2,SZ). Remember that the Maildir specifications require that the
#         flags are sorted by their ASCII value, although Dovecot itself doesn't care about that.
#
# Unlock the maildir by sending a TERM signal to the maildirlock process (killing the PID it wrote to stdout).

# Variables initialization
dryrun=false
compress="bzip2"
action="compress"
store=""
days=30
warn_mismatch=false
maxdepth=""
verbose=false

function usage {
    echo "Usage: $(basename $0) ([-b|-c|-d|-D|-g|-l|-s|-t <days>|-v|-w]) /path/to/maildir" >&2
    echo "    -b - use bzip2 (default)"  >&2
    echo "    -c - compress (default)" >&2
    echo "    -d - decompress"  >&2
    echo "    -D - dry-run - will not perform any actions, will only report"  >&2
    echo "    -g - use gzip"  >&2
    echo "    -l - use lzma/xz (check if dovecot version supports it)" >&2
    echo "    -s - don't process subdirectories (max depth of 1)" >&2
    echo "    -t <days> - minimum message age in days (default 30)" >&2
    echo "    -v - verbose, print informational and warning messages about the progress" >&2
    echo "    -w - enable warnings for unprocessed files due to mime type mismatch" >&2
    echo "" >&2
    exit 127;
}

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
# Disable colours (ie "No colour")
NC='\033[0m'

function print_info {
    if $verbose; then
        echo -ne "\r\e[K[ ${BLUE}INFO${NC} ] $1\n"
    fi
}

function print_error {
    echo -ne "\r\e[K[ ${RED}ERR${NC}  ] $1\n"
}

function print_warning {
    if $verbose; then
        echo -ne "\r\e[K[ ${YELLOW}WARN${NC} ] $1\n"
    fi
}

function print_done {
    echo -ne "\r\e[K[ ${GREEN}DONE${NC} ] $1\n"
}

function print_progress {
    echo -ne "\r\e[K$1"
}

while getopts :bcdDghlst:vw option; do
    case "${option}" in
        b) compress="bzip2" ;;
        c) action="compress" ;;
        d) action="decompress" ;;
        D) dryrun=true ;;
        g) compress="gzip" ;;
        h) usage ;;
        l) compress="xz" ;;
        s) maxdepth="-maxdepth 1" ;;
        t)
            if [ "$OPTARG" -ne "$OPTARG" ] 2>/dev/null || [ $? -eq 2 ]; then
                echo "Number of days is not a number." >&2
                usage
            fi
            days=$((OPTARG-1))
        ;;
        v) verbose=true ;;
        w) warn_mismatch=true ;;
        \?) echo "Invalid option: -$OPTARG" >&2; usage ;;
    esac
done

# shift out opts
shift $((OPTIND -1))

if [[ "x$@" == "x" ]]; then
    echo "No maildir provided."
    usage
fi

if $dryrun; then
    print_info "Dry-run mode, will not actually perform (de)compression or moving of mails..."
fi

store=$@

# Find all of the "cur" directories in the provided location
# This would contain any current (read) messages. We don't want to touch the
# "new" directory as the IMAP server may move the mail to "cur" at any given time.
# The "tmp" directory is where the messages are delivered by the MDA (dovecot)
# before they are moved to "new".
find "$store" $maxdepth -type d -name "cur" | while read maildir_cur; do

    maildir_base=$(realpath "$maildir_cur/..")
    maildir_tmp=""
    # Check if "$maildir_cur/../tmp" exists and is a directory
    # If it exists then define maildir_tmp as the path otherwise exit
    if [ -d "$maildir_cur/../tmp" ]; then
        maildir_tmp="$(realpath "$maildir_cur/../tmp" 2>/dev/null)"
    else
        print_error "Temp dir not found, skipping ${maildir_base}..."
        continue
    fi

    lockfile="${maildir_base}/dovecot-uidlist.lock"

    files_found=""

    # Maildir filenames are in the format
    # <timestamp>.<uniqueness qualifier/id>.<mail system hostname>,S=<size>,W=<vsize>:2,<flags>
    # The uniqueness qualifier is in the format <letter><numbers><letter><numbers> where these vary
    # for the different systems. I've seen the first letter as M, H and V, whereas the second was always a P.
    # size is the total size of the mail message
    # vsize is the RFC822 size, ie the size with line endings set to CRLF instead of LF only (ie, Windows...)
    # Sometimes the vsize may be missing.
    # From the upstream there was a `-name "*,S=*"` here, but turns out some older formats do not even have
    # the sizes in the file name
    files_found=$(find "$maildir_cur" -type f -mtime +$days -printf "%f\n")

    if [ -z "$files_found" ]; then
        print_info "No files found in ${maildir_cur}, skipping..."
        print_done "$(dirname "$maildir_cur")"
        continue
    fi

    total=$(echo "$files_found"|wc -l)
    count=0
    file_count=0

    # while; do < <(input) loop because the file_count var needs to be accessible from outside the loop
    while read filename; do
        count=$((count+1))

        print_progress "[ $count/$total ] $(dirname "$maildir_cur") - Looking for files for ${action}ion..."

        srcfile="$maildir_cur/$filename"
        tmpfile="$maildir_tmp/$filename"

        if $dryrun ; then
                # Not performing any actoins in dry run mode
                print_info "DRY: Check if ${srcfile} needs ${action}ing"
                print_info "DRY: ${action^}ing ${srcfile} into ${tmpfile} with file attributes"
                continue
        fi

        # Check the file and act accordingly:
        # - if it's compressed and compression was requested, skip it
        # - if it's compressed and decompression was requested, decompress into the tmp dir
        # - if it's not compressed and compression was requested, compress into the tmp dir
        # - if it's not compressed and decompression was requested, skip it

        # Using the mime type check here instead of the default for `file` since there are many
        # text files, but they all share the same mime type - makes mismatch output a bit more uniform
        mime_type=$(file -b --mime-type "$srcfile")
        is_compressed=""
        if [ \
            "$mime_type" = "application/gzip" -o \
            "$mime_type" = "application/x-gzip" -o \
            "$mime_type" = "application/x-bzip2" -o \
            "$mime_type" = "application/x-xz" \
        ]; then
            is_compressed=$(echo $mime_type | cut -d '/' -f 2 | cut -d '-' -f 2)
        fi

        # file_type=$(file -b "$srcfile" | awk '{print tolower($1)}')
        # if [[ "$file_type" =~ (xz|bzip2|gzip) ]]; then
        #     is_compressed=${BASH_REMATCH[1]}
        # fi

        if [ "$action" = "compress" -a "$is_compressed" = "" ]; then
            $compress --best --stdout "$srcfile" > "$tmpfile"
        elif [ "$action" = "decompress" -a "$is_compressed" != "" ]; then
            $is_compressed --decompress --stdout "$srcfile" > "$tmpfile"
        else
            if $warn_mismatch; then
                print_warning "Can't ${action} ${srcfile}, mime type is ${mime_type}. Skipping..."
            fi
            continue
        fi

        # Copy over the owner, modes and modification time from source
        chown --reference="$srcfile" "$tmpfile"
        chmod --reference="$srcfile" "$tmpfile"
        touch --reference="$srcfile" "$tmpfile"
        file_count=$((file_count+1))
    done < <(echo "$files_found")

    if $dryrun ; then
        # Same as the previous loop - no need to do anything in dry run mode
        # but we also don't want to lock the dir, plus there will be no files to work with
        # in the tmp directory
        sleep 1
        print_done "$(dirname "$maildir_cur")"
        continue
    fi

    if [ "$file_count" -gt 0 ]; then
        print_info "Copied ${file_count} files in tmp"
    else
        print_info "No files were found for ${action}ing"
        print_done "$(dirname "$maildir_cur")"
        continue
    fi

    # Should really check dovecot-uidlist is in $maildir_cur/..
    if lock=$(touch "$lockfile" && flock -w 10 -n "$maildir_cur" true || false); then
        # The directory is locked now

        count=0

        echo "$files_found" | while read filename; do
            count=$((count+1))

            print_progress "[ $count/$total ] $(dirname "$maildir_cur") - Moving mails..."

            # flags=$(echo $filename | awk -F:2, '{print $2}')

            # http://wiki2.dovecot.org/MailboxFormat/Maildir
            # The standard filename definition is: "<base filename>:2,<flags>".
            # Dovecot has extended the <flags> field to be "<flags>[,<non-standard fields>]".
            # This means that if Dovecot sees a comma in the <flags> field while updating flags in the filename,
            # it doesn't touch anything after the comma. However other maildir MUAs may mess them up,
            # so it's still not such a good idea to do that. Basic <flags> are described here. The <non-standard fields> isn't used by Dovecot for anything currently.

            # There is no point dealing with additional flags dovecot or any other program doesn't care about
            # As such, we will just copy the decompressed file back, without ajusting the name at all
            
            srcfile="${maildir_cur}/${filename}"
            tmpfile="${maildir_tmp}/${filename}"


            if [ -f "$srcfile" ] && [ -f "$tmpfile" ]; then
                mv "$tmpfile" "$srcfile"
            fi

            if [ -f "$tmpfile" ]; then
                rm -f "$tmpfile"
            fi
        done

    else
        echo "Failed to lock: $maildir_cur" >&2

        echo "$files_found" | while read filename; do
                rm -f "$maildir_tmp/$filename"
        done
    fi

    flock -u "$maildir_cur" rm -f "$lockfile"
    print_done "$(dirname "$maildir_cur")"
done
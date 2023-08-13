#!/bin/bash

# 2023-08-13 - Forked from https://github.com/George-NG/dovecot-maildir-compress 
# * Changed locking to use flock instead of maildirlock due to segfaulting issues on cpanel servers.
# * Added detection of compressed file types when decompressing
# * Changed the way tmpdir is defined 

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

## Based on:
## https://gist.github.com/cs278/1490556
## http://ivaldi.nl/blog/2011/12/06/compressed-mail-in-dovecot/
##

# Variables initialization
debug=false
compress="bzip2"
action="compress"
store=""
days=30

function usage {
        echo "Usage: $(basename $0) ([-b|-c|-d|-g|-l|-t <days>]) /path/to/maildir" >&2
        echo "    -c - compress (default)" >&2
        echo "    -d - decompress"  >&2
        echo "    -b - use bzip2 (default)"  >&2
        echo "    -g - use gzip"  >&2
        echo "    -l - use lzma/xz (check if dovecot version supports it)" >&2
        echo "    -t <days> - minimum message age in days (default 30)" >&2
        echo "" >&2
        exit 127;
}

while getopts :bcdDghlt: option; do
        case "${option}" in
                b) compress="bzip2" ;;
                c) action="compress" ;;
                d) action="decompress" ;;
                D) debug=true ;;
                g) compress="gzip" ;;
                l) compress="xz" ;;
                t)
                        if [ "$OPTARG" -ne "$OPTARG" ] 2>/dev/null ; then
                                echo "Number of days is not a number." >&2
                                usage
                        fi
                        days=$((OPTARG-1))
                ;;
                h) usage ;;
                \?) echo "Invalid option: -$OPTARG" >&2; usage ;;
        esac
done

# shift out opts
shift $((OPTIND -1))

if [[ "x$@" == "x" ]]; then
        echo "No maildir provided."
        usage
fi

# Multiple dirs?
# not for now...
#for store in $@; do

if $debug; then
        echo "Debug mode, will not actually perform compression or moving of mails..."
fi

store=$@

        find "$store" -type d -name "cur" | while read maildir; do

                # Check if "$maildir/../tmp" exists and is a directory
                # If it exists then define tmpdir as the path otherwise exit
                [[ -d "$maildir/../tmp" ]] && tmpdir="$maildir/../tmp" || exit 1
                lockfile="$maildir/../dovecot-uidlist.lock"

                find=""
                if [[ "$action" == "compress" ]]; then
                        find=$(find "$maildir" -type f -name "*,S=*" -mtime +$days ! -name "*,*:2,*,*Z*" -printf "%f\n")
                else
                        find=$(find "$maildir" -type f -name "*,S=*" -mtime +$days -name "*,*:2,*,*Z*" -printf "%f\n")
                fi

                if [ -z "$find" ]; then
                        continue
                fi

                total=$(echo "$find"|wc -l)
                count=0

                echo "$find" | while read filename; do
                        count=$((count+1))



                        echo -ne "\r\e[K[ $count/$total ] \"$(dirname "$maildir")\" - ${action^}ing..."

                        srcfile="$maildir/$filename"
                        tmpfile="$tmpdir/$filename"

                        if $debug ; then
                                # Not performing any actoins in debug mode
                                sleep 2
                                continue
                        fi

                        if [[ "$action" == "compress" ]]; then
                                $compress --best --stdout "$srcfile" > "$tmpfile"
                        else
                                # Autodetect compressed file type and use it as the decompression binary filename
                                [[ "$(file -b "$srcfile" | awk '{print tolower($1)}')" =~ (xz|bzip2|gzip) ]] \
                                        && decompress=${BASH_REMATCH[1]} \
                                        || decompress=$compress
                                $decompress --decompress --stdout "$srcfile" > "$tmpfile"
                        fi

                        # Copy over some things
                        chown --reference="$srcfile" "$tmpfile" &&
                        chmod --reference="$srcfile" "$tmpfile" &&
                        touch --reference="$srcfile" "$tmpfile"
                done

                if $debug ; then
                        # Same as the previous loop - no need to do anything in debug mode
                        # but we also don't want to lock the dir
                        sleep 1
                        # Because we are skipping the rest of the loop...
                        echo -e "\r\e[K[ Done ] \"$(dirname "$maildir")\""
                        continue
                fi

                # Should really check dovecot-uidlist is in $maildir/..
                if lock=$(touch "$lockfile" && flock -w 10 -n "$maildir" true || false); then
                        # The directory is locked now

                        count=0

                        echo "$find" | while read filename; do
                                count=$((count+1))
                                echo -ne "\r\e[K[ $count/$total ] \"$(dirname "$maildir")\" - Moving mails..."

                                flags=$(echo $filename | awk -F:2, '{print $2}')

                                # http://wiki2.dovecot.org/MailboxFormat/Maildir
                                # The standard filename definition is: "<base filename>:2,<flags>".
                                # Dovecot has extended the <flags> field to be "<flags>[,<non-standard fields>]".
                                # This means that if Dovecot sees a comma in the <flags> field while updating flags in the filename,
                                # it doesn't touch anything after the comma. However other maildir MUAs may mess them up,
                                # so it's still not such a good idea to do that. Basic <flags> are described here. The <non-standard fields> isn't used by Dovecot for anything currently.

                                # Because of the above, we are adding "," before "Z" to designate it as custom flag
                                if [[ "$action" == "compress" ]]; then
                                        # Add "Z" to existing flags or along with "," if there are no other custom flags
                                        if echo $flags | grep ',' &>/dev/null ; then
                                                newname=$filename"Z"
                                        else
                                                newname=$filename",Z"
                                        fi
                                else
                                        # Remove "Z" from the flags
                                        if echo $flags | grep ',' &>/dev/null; then
                                                # We know that a compressed mail will have a "Z" in the filename already, sed
                                                # is *very* gready and will match till the last possible character. Also, it will be good
                                                # to remove the comma if its the last in the filename (because of the custom flags)
                                                newname=$(echo "$filename"|sed -e 's/\(.*\)Z/\1/; s/,$//')
                                        else
                                                # We should never ever land here, but give it a filename again, just in case...
                                                newname=$(echo "$filename"|sed -e 's/\(.*\)Z/\1/')
                                        fi
                                fi

                                srcfile=$maildir/$filename
                                tmpfile=$tmpdir/$filename
                                dstfile=$maildir/$newname

                                if [ -f "$srcfile" ] && [ -f "$tmpfile" ]; then
                                        #echo "$srcfile -> $dstfile"

                                        mv "$tmpfile" "$srcfile" &&
                                        mv "$srcfile" "$dstfile"
                                else
                                        rm -f "$tmpfile"
                                fi
                        done

                else
                        echo "Failed to lock: $maildir" >&2

                        echo "$find" | while read filename; do
                                rm -f "$tmpdir/$filename"
                        done
                fi
                flock -u "$maildir"
                rm -f "$lockfile"
                echo -e "\r\e[K[ Done ] \"$(dirname "$maildir")\""
        done
#done

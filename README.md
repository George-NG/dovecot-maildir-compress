# dovecot-maildir-compress

Compress and decompress mails in a maildir directory structure, for use with dovecot's zlib plugin.

More information can be found in dovecot documentation:

[Dovecot Pro 3.0.2](https://doc.dovecotpro.com/3.0.2/core/plugins/mail_compress.html#mail-compression-mail-compress-plugin)

[Dovecot Core 2.4.1](https://doc.dovecot.org/2.4.1/core/plugins/mail_compress.html#mail-compression-plugin-mail-compress)

# Why?

I needed a script for compressing mails on a mail server at the time of switching to using the zlib plugin. While searching for something, I landed on a github gist page pointing to a blog post with good enough script for the job. The problem however was that the script wasn't really showing any output and I wanted it to be easier to run against multiple directories with one run, or at least display the progress of the script.

# So what's new?

I've added a simple "progress bar" to show which directory is currently being worked on - useful when you have a (couple of) terabyte(s) of e-mails to compress. Added different command line arguments, so you can use the script for both compressing and decompressing mails.

Also you can chose between the 3 compression types supported by the dovecot zlib plugin (at the time of creating this). You can select message file age (as in how long a go it was added to the directory), which allows you to compress mails after a certain amount of time.

Still testing? There is dry-run and increased verbosity modes.

# Caveats

With previous iterations of the script, the filename was getting modified to add a `Z` flag to indicate the message is compressed. This could cause errors to be thrown in the log as well as prevent the users of the mail system to see certain information about their e-mails.

With the latest changes to the script, the filename does not change, however issues may still arise from modifying the files. If that's the case for you, you as the operator of your mail system should force the dovecot index to be rebuilt by deleting the `dovecot.index` file(s) in your maildir(s) and then reloading dovecot.

As `xz` is phased out of dovecot (and possibly other software solutions) likely due to the backdoor issue, you shouldn't use it going forward for compressing mails. The functionality will remain here for anyone that still needs to migrate.

# Usage

## All options

```bash
Usage: dovecot-maildir-compress.sh ([-b|-c|-d|-D|-g|-l|-s|-t <days>|-v|-w]) /path/to/maildir
    -b - use bzip2 (default)
    -c - compress (default)
    -d - decompress
    -D - dry-run - will not perform any actions, will only report
    -g - use gzip
    -l - use lzma/xz (check if dovecot version supports it)
    -s - don't process subdirectories (max depth of 1)
    -t <days> - minimum message age in days (default 30)
    -v - verbose, print informational and warning messages about the progress
    -w - enable warnings for unprocessed files due to mime type mismatch
```

## Usage examples

Compress mails older thant 60 days with xz (will not work with latest dovecot, check the Caveats section):

```bash
/path/to/dovecot-maildir-compress.sh -clt 60 /path/to/maildir
```

Decompress all mails, auto-detecting the application used for compression:

```bash
/path/to/dovecot-maildir-compress.sh -dt 0 /path/to/maildir
```

Compress all mail with bzip2(default), printing additional information on the progress:

```bash
/path/to/dovecot-maildir-compress.sh -cvwt 0 /path/to/maildir
```

Compress all mail in the top level directory (inbox) without recursion into additional mailboxes/labels:

```bash
/path/to/dovecot-maildir-compress.sh -cst 0 /path/to/maildir
```

# TODO

With the first iteration I wanted to make it possible to process multiple directories. I haven't really found myself wanting that feature to exist, so I haven't implemented it. As the script already checks all subdirs for a `cur` directory, you can run it at the top of your maildir home (ie `/var/vmal`) and it will pick up all user accounts and (de)compress their e-mails. Still not ideal if you want to do this for say 2 out of thousands of mailboxes...

# CHANGELOG

## 2025-09-13 by @George-NG

- Renamed the debug name and var to "dryrun" as that's more appropriate for what that is used for
- Updated the dryrun output to be a bit more verbose about what would be done
- Renamed the variables for the `cur` and `tmp` directories to make them more descriptive
- Added extra arguments for displaying warnings, and for selecting depth of operation and verbosity
- Added convenience functions for printing out messages on the screen
- Added additional colours to the output, in use with the printing functions
- Changed indentation throughout the script - the original was using 8 spaces (tabs), changed it to 4 and re-indented everything
- Changed the "find" variable to "files_found", as it wasn't very descriptive. This allowed for additional checks to be added and to display additional information
- Removed the file search based on flag in the file name. Instead, all files have their mime-type checked and acted on according to the selected action.
- Added additional check for number of files found for the selected operation. This allows us to skip the whole section of moving the files back to `cur`, and because of that - not having to lock the maildir and do nothing with the lock.
- Removed the whole section which was updating the file name to add the `Z` flag - dovecot does not care about these flags and this modification can cause problems with the service (check the README)

## 2023-08-13 by @styelz
- Changed locking to use flock instead of maildirlock due to segfaulting issues on cpanel servers.
- Added auto detection of compressed file types when decompressing
- Changed the way tmpdir is checked and defined 

# dovecot-maildir-compress
Compress and decompress mails in a maildir directory structure, for use with dovecot's zlib plugin.
More information can be found here: https://doc.dovecot.org/3.0/configuration_manual/mail_compress_plugin/

# Why?
I needed a script for compressing mails on a mail server at the time of switching to using the zlib plugin. While searching for something, I landed on a github gist page pointing to a blog post with good enough script for the job. The problem however was that the script wasn't really showing any output and I wanted it to be easier to run against multiple directories with one run.

# So what's new?
I've added a simple "progress bar" to show which directory is currently being worked on - useful when you have a (couple) of terabyte(s) of e-mails to compress. Added different command line arguments, so you can use the script for both compressing and decompressing mails. Also you can chose between the 3 compression types supported by the dovecot zlib plugin. You can select message file age (eg how long a go it was added to the directory), which allows you to compress mails after a certain amount of time.
Still testing? There is debug mode.

# Usage
Compress mails older thant 60 days with xz
```bash
/path/to/dovecot-maildir-compress -c -l -t 60 /path/to/maildir
```
Decompress all mails using bzip2
```bash
/path/to/dovecot-maildir-compress -d -b -t 0 /path/to/maildir
```

# TODO:
- Move the debug messages in a separate function, tidy up the code. Output debug to stderr instead of stdout.
- Pass multiple dirs as arguments to the script

# CHANGELOG:
- Changed locking to use flock instead of maildirlock due to segfaulting issues on cpanel servers.
- Added auto detection of compressed file types when decompressing
- Changed the way tmpdir is checked and defined 

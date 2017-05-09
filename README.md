# dovecot-maildir-compress
Compress and decompress mails in a maildir directory structure, for use with dovecot's zlib plugin

# Why?
I needed a script for compressing mails on a mail server at the time of switching to using the zlib plugin. While searching for something, I landed on a github gist page pointing to a blog post with good enough script for the job. The problem however was that the script wasn't really showing any output and I wanted it to be easier to run against multiple directories with one run.

# So what's new?
I've added a simple "progress bar" to show which directory is currently being worked on - useful when you have a (couple) of terabyte(s) of e-mails to compress. Added different command line arguments, so you can use the script for both compressing and decompressing mails. Also you can chose between the 3 compression types supported by the dovecot zlib plugin. You can select message file age (eg how long a go it was added to the directory), which allows you to compress mails after a certain amount of time.
Still testing? There is debug mode.

# TODO:
- Add file autodetection, to be able to decompress compressed mails, no matter the compression type. Useful if we have mails not compressed with this script and/or multiple types.
- Move the debug messages in a separate function, tidy up the code. Output debug to stderr instead of stdout.
- Pass multiple dirs as arguments to the script
- Fix the following line to use dirname or realpath instead of cd && pwd:
```bash
  tmpdir=$(cd "$maildir/../tmp" &>/dev/null && pwd) || exit 1
```

# snap

`snap.sh` backs up config files: it copies every `*.conf` file directly in `SRC` (not in its
subdirectories) to `DEST/<name>.bak`, creating `DEST` if needed.

## Usage

    ./snap.sh /etc/myapp ~/backups/myapp

## Tests

    make test

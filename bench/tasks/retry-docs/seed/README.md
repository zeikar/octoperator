# retry

`retry.sh` runs a command again and again until it succeeds, with a pause between attempts. Use it
for steps that fail now and then, such as a health check on a service that is still starting.

## Usage

    ./retry.sh curl -fsS http://localhost:8080/health

Messages about failed attempts go to stderr; the command's own output is passed through unchanged.

## Tests

    make test

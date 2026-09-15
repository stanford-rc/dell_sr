# dell_sr

Command-line client for the Dell TechDirect Technical Support Request REST API.
It uses the production API to create, retrieve, update, attach files to, and
close Dell support requests.

## Requirements

- Bash
- curl
- jq
- GNU coreutils (`readlink`, `stat`, and `split`)

## Credentials

Place the production OAuth credentials in `.creds` beside the script:

```text
client_id:client_secret
```

Restrict the file to its owner:

```console
chmod 600 .creds
```

Credentials can instead be supplied through `DELL_SR_CLIENTID` and
`DELL_SR_SECRET`. The script caches the OAuth token under
`$XDG_CACHE_HOME/dell-techdirect`, or `~/.cache/dell-techdirect` when
`XDG_CACHE_HOME` is unset.

## Usage

```text
Usage:  dell_sr.sh [-j] [-d] COMMAND [ARGS]

        -j  output JSON
        -d  write the last raw API response to dell_sr_dump.json

Commands:
  auth
  register CLIENT_JSON
  create CASE_JSON
  get SR_NUMBER SERVICE_TAG
  note SR_NUMBER TEXT|@FILE
  attach SR_NUMBER EMAIL FILE
  close CLOSE_JSON CONFIRM_SR_NUMBER
```

Register the client once before creating support requests:

```console
./dell_sr.sh register register.json
```

Common operations:

```console
./dell_sr.sh auth
./dell_sr.sh create case.json
./dell_sr.sh get 123456789 ABC1234
./dell_sr.sh note 123456789 "Diagnostic completed"
./dell_sr.sh attach 123456789 user@example.com diagnostics.zip
./dell_sr.sh close close.json 123456789
```

The `register`, `create`, and `close` commands accept the JSON payloads defined
in Dell's SDK. Download the current Technical Support Request SDK from the API
tile in [TechDirect](https://techdirect.dell.com/). The SDK is confidential and
is not included in this repository.

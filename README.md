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

### Register the client

Register once for each TechDirect customer instance. Create `register.json`
with the company and primary support contact:

```json
{
  "id": "0",
  "type": "HELPDESK",
  "ipaddress": "192.0.2.10",
  "companyName": "Example Company",
  "countryCodeISO": "USA",
  "emailOptIn": true,
  "primaryContact": {
    "firstName": "Jane",
    "lastName": "Doe",
    "phoneNumber": "6505550100",
    "emailAddress": "jane.doe@example.com",
    "preferredLanguage": "en"
  }
}
```

Replace the example values with the real company, client IP address, and
contact information. Keep `id` set to `0` for the initial registration, then
submit the file:

```console
./dell_sr.sh register register.json
```

The registration `type` and the case payload's `client.type` identify the API
client integration. For this API, use `HELPDESK` in both places. This field
does not describe the affected hardware; the hardware category belongs in
`device.type`, such as `PowerEdge`. Use another client type only if Dell assigns
one for a different integration model.

Save the `client ID` returned by Dell. It is required in every case payload.
Registration should not be repeated unless Dell directs you to register a new
customer instance.

### Create a support request

Create `case.json` using the registered client ID, the affected system's
service tag, and a description of the problem:

```json
{
  "eventId": "2",
  "eventSource": "Server",
  "timestamp": "2026-09-15T19:00:00Z",
  "message": "GPU 1 reports uncorrectable memory errors and row remapping failed.",
  "client": {
    "id": "YOUR_REGISTERED_CLIENT_ID",
    "type": "HELPDESK",
    "ipAddress": "192.0.2.10",
    "companyName": "Example Company",
    "countryCodeISO": "USA",
    "primaryContact": {
      "firstName": "Jane",
      "lastName": "Doe",
      "phoneNumber": "6505550100",
      "emailAddress": "jane.doe@example.com",
      "preferredLanguage": "en"
    }
  },
  "device": {
    "serviceTag": "ABC1234",
    "type": "PowerEdge"
  }
}
```

Use the current UTC time for `timestamp`. The `message` field describes the
failure and accepts up to 7,500 characters. Dell marks it as optional, but a
new request should include enough detail for Technical Support to investigate.

`eventSource` identifies the hardware category, and its `eventId` or `trapId`
must use Dell's matching value:

| Hardware category | `eventSource` | `eventId` | `trapId` |
| --- | --- | --- | --- |
| Client device | `Client` | `1` | `0` |
| Server | `Server` | `2` | `0` |
| Storage | `Storage` | `3` | `0` |
| Direct-attached storage | `DirectAttach` | `4` | `0` |

Dell requires at least one of `eventId` or `trapId`. The example supplies the
server `eventId` and omits `trapId`. An invalid identifier, an unsupported
source, or a mismatched combination causes case creation to fail.

If an API-created request is already active for the service tag, Dell appends
the new report to that request instead of opening a duplicate.

Submit the payload with:

```console
./dell_sr.sh create case.json
```

### Close a support request

Close a request only after the issue is resolved. Create `close.json` with the
five fields required by Dell:

```json
{
  "clientID": "YOUR_REGISTERED_CLIENT_ID",
  "clientType": "HELPDESK",
  "companyName": "Example Company",
  "serviceTag": "ABC1234",
  "srNumber": "123456789"
}
```

Use the client ID and company name from registration. `clientType` corresponds
to the registration `type` and should remain `HELPDESK`. The service tag and SR
number must identify the request being closed.

Pass the SR number again on the command line:

```console
./dell_sr.sh close close.json 123456789
```

The script refuses to continue unless that confirmation matches `srNumber` in
the JSON file. Dell requires contacting Technical Support within 10 days to
reopen a closed request.

### Other operations

```console
./dell_sr.sh auth
./dell_sr.sh get 123456789 ABC1234
```

Add a note directly or read it from a file. Notes are limited to 10,000
characters:

```console
./dell_sr.sh note 123456789 "Diagnostic completed"
./dell_sr.sh note 123456789 @note.txt
```

An argument beginning with `@` names a file. Use `@@` when the note text itself
must begin with `@`; the script removes the first character:

```console
./dell_sr.sh note 123456789 "@@on-call confirmed the repair"
```

Attach a supporting file with the requester's email address:

```console
./dell_sr.sh attach 123456789 user@example.com diagnostics.zip
```

The script divides files into chunks no larger than 20 MiB, uploads them in
order, and polls Dell's vulnerability scan for about two minutes. If the scan
has not reported `Completed`, the script reports that Dell
accepted the upload but did not confirm it within the polling period.

Dell rejects these attachment extensions: `asp`, `aspx`, `axd`, `asx`, `asmx`,
`ashx`, `shtml`, `mhtml`, `xhtml`, `mht`, `scr`, `lnk`, `msi`, `msp`, `ps1`,
`reg`, `vb`, `vbs`, `hta`, `ws`, and `dll`.

### Troubleshooting

Use `-j` to print the API response as JSON. Use `-d` to save the last raw API
response to `dell_sr_dump.json`. Set `DEBUG=1` to print request methods, URLs,
and HTTP status codes without printing credentials or access tokens:

```console
DEBUG=1 ./dell_sr.sh -j -d get 123456789 ABC1234
```

The `auth` command requests a fresh OAuth token. It confirms that Dell accepts
the configured OAuth credentials, but it does not test access to the support
request endpoints.

The `register`, `create`, and `close` commands accept the JSON payloads defined
in Dell's SDK. Download the current Technical Support Request SDK from the API
tile in [TechDirect](https://techdirect.dell.com/).

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

Create `case.json` using the registered client ID and the affected system's
service tag:

```json
{
  "eventId": "1",
  "eventSource": "Client",
  "timestamp": "2026-09-15T19:00:00Z",
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

Use the current UTC time for `timestamp`. Dell requires at least one of
`eventId` or `trapId`; the identifier must be valid for the selected
`eventSource`. If an API-created request is already active for the service tag,
Dell appends the new report to that request instead of opening a duplicate.

Submit the payload with:

```console
./dell_sr.sh create case.json
```

### Other operations

```console
./dell_sr.sh auth
./dell_sr.sh get 123456789 ABC1234
./dell_sr.sh note 123456789 "Diagnostic completed"
./dell_sr.sh attach 123456789 user@example.com diagnostics.zip
./dell_sr.sh close close.json 123456789
```

The `register`, `create`, and `close` commands accept the JSON payloads defined
in Dell's SDK. Download the current Technical Support Request SDK from the API
tile in [TechDirect](https://techdirect.dell.com/).

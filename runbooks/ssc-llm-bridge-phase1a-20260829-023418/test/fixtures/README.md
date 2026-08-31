# Test fixtures

- `valid-request.json`: canonical multibyte UTF-8 request envelope.
- `duplicate-key-request.json`: duplicate JSON member rejection.
- `unknown-field-request.json`: strict additional-property and request-supplied model rejection.
- `lone-surrogate-request.json`: escaped unpaired Unicode surrogate rejection.
- `malformed-utf8.hex`: raw invalid UTF-8 bytes represented as hex for deterministic source control.
- `utf8-bom.hex`: UTF-8 BOM fixture represented as hex.
- `ollama-inventory-valid.json`: exact pinned model name and digest.
- `ollama-inventory-wrong-digest.json`: fail-closed inventory mismatch.
- `ollama-response-valid.json`: bounded mock assistant response.
- `ollama-response-tool-call.json`: tool-call schema rejection.

The test runner decodes the `.hex` fixtures into their exact raw bytes. All HTTP tests use temporary listeners bound to `127.0.0.1`; no live Ollama or external network endpoint is contacted.

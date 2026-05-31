Vendored patch of [dirs-sys](https://github.com/dirs-dev/dirs-sys-rs) 0.5.0 for Windows 7.

Upstream 0.5.0 allows `windows-sys >= 0.59`, which Cargo resolves to 0.61. That
version links `CoTaskMemFree` to `combase.dll` (Windows 8+). This patch pins
`windows-sys` 0.59, which links it to `ole32.dll` (available on Windows 7).

Remove when upstream provides a Win7-compatible release or when Win7 support is
dropped.

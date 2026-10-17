# Gate helper: prove app-release.apk carries the freshly built libapp.so.
#
# Why this exists: the APK byte length is page-aligned and repeats at exactly
# 29,601,772 across unrelated builds, so "the sizes match" proves nothing about
# which code shipped. This extracts the APK's own copy of the native snapshot
# and compares SHA256 against Gradle's stripped output, then fails loudly if
# either side is missing or hashes to nothing (an empty-vs-empty comparison once
# reported MATCH=True through a path bug, which is the failure mode to guard).
#
# Usage (a bare double-click is blocked by the execution policy):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tool\verify_apk_so.ps1
param(
  # Optional: literal strings that must appear in the AOT snapshot, proving the
  # change under test survived compilation. Symbols are stripped, so prefer
  # names that survive as string literals (print text, Firestore field paths,
  # collection keys). Pass comma-separated.
  [string[]]$MustContain = @(),
  # The negative half of the proof: literals that must NOT be present, used to
  # show deleted or renamed code really left the binary rather than surviving as
  # dead weight. Same comma-separated form.
  [string[]]$MustNotContain = @()
)

Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = Split-Path -Parent $PSScriptRoot   # script lives in <root>\tool
Set-Location $root

$built = Join-Path $root 'build\app\intermediates\stripped_native_libs\release\stripReleaseDebugSymbols\out\lib\arm64-v8a\libapp.so'
# 13 MB scratch extract; lives under build\ (gitignored) and is removed in the
# finally block below so it cannot be left behind.
$extracted = Join-Path $root 'build\apk_libapp.so'
$apk = Join-Path $root 'app-release.apk'

if (-not (Test-Path $apk)) { throw "missing APK: $apk" }
if (-not (Test-Path $built)) { throw "missing built snapshot: $built" }

try {
  $zip = [System.IO.Compression.ZipFile]::OpenRead($apk)
  try {
    $entry = $zip.GetEntry('lib/arm64-v8a/libapp.so')
    if ($null -eq $entry) { throw 'lib/arm64-v8a/libapp.so not found in APK' }
    $src = $entry.Open()
    $dst = [System.IO.File]::Create($extracted)
    $src.CopyTo($dst)
    $dst.Close()
    $src.Close()
    $entryLen = $entry.Length
  } finally {
    $zip.Dispose()
  }

  $a = (Get-FileHash $extracted -Algorithm SHA256).Hash
  $b = (Get-FileHash $built -Algorithm SHA256).Hash
  if ([string]::IsNullOrEmpty($a) -or [string]::IsNullOrEmpty($b)) {
    throw 'empty hash - comparison invalid'
  }

  "APK_SO    = $a"
  "BUILD_SO  = $b"
  "MATCH     = $($a -eq $b)"
  "APK_LEN   = $((Get-Item $apk).Length)  SO_LEN = $entryLen  BUILT_LEN = $((Get-Item $built).Length)"
  "SO_MTIME  = $((Get-Item $built).LastWriteTime)"

  if ($MustContain.Count -gt 0 -or $MustNotContain.Count -gt 0) {
    # Latin1 (28591) maps every byte to one char, so no decoding damage in a
    # binary file.
    $text = [Text.Encoding]::GetEncoding(28591).GetString(
      [IO.File]::ReadAllBytes($built))
    # With `-File script.ps1 -MustContain a,b,c` PowerShell's file binder hands
    # over ONE string, commas and all, so a naive loop searches for the joined
    # text and always reports False. Split every element, then trim empties.
    $needles = @($MustContain | ForEach-Object { $_ -split ',' } |
      ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $absent = @($MustNotContain | ForEach-Object { $_ -split ',' } |
      ForEach-Object { $_.Trim() } | Where-Object { $_ })
    "Symbol scan of $(($text.Length / 1MB).ToString('0.0')) MB snapshot:"
    $failed = 0
    foreach ($s in $needles) {
      $hit = $text.Contains($s)
      if (-not $hit) { $failed++ }
      "  present=$hit  <- $s"
    }
    foreach ($s in $absent) {
      $hit = $text.Contains($s)
      if ($hit) { $failed++ }
      "  gone=$(-not $hit)  <- $s"
    }
    if ($failed -gt 0) { throw "$failed symbol check(s) failed" }
  }

  if ($a -ne $b) { throw 'APK does not contain the freshly built libapp.so' }
} finally {
  Remove-Item $extracted -Force -ErrorAction SilentlyContinue
}

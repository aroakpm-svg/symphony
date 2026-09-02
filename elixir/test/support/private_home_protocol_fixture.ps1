param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('delay', 'malformed', 'mismatch', 'reject', 'unique')]
  [string]$Mode
)

$ErrorActionPreference = 'Stop'
$seen = @{}

while ($null -ne ($line = [Console]::In.ReadLine())) {
  $request = $line | ConvertFrom-Json
  $correlationId = [string]$request.id

  switch ($Mode) {
    'delay' {
      Start-Sleep -Milliseconds 250
      [Console]::Out.WriteLine((@{ id = $correlationId; ok = $true; code = 'committed' } | ConvertTo-Json -Compress))
      [Console]::Out.Flush()
      return
    }

    'malformed' {
      [Console]::Out.WriteLine('{not-json')
      [Console]::Out.Flush()
      return
    }

    'mismatch' {
      [Console]::Out.WriteLine((@{ id = "$correlationId-mismatch"; ok = $true; code = 'committed' } | ConvertTo-Json -Compress))
      [Console]::Out.Flush()
      return
    }

    'reject' {
      [Console]::Out.WriteLine((@{ id = $correlationId; ok = $false; code = 'operation_failed' } | ConvertTo-Json -Compress))
      [Console]::Out.Flush()
      return
    }

    'unique' {
      if ([string]::IsNullOrWhiteSpace($correlationId) -or $seen.ContainsKey($correlationId)) {
        [Console]::Out.WriteLine((@{ id = $correlationId; ok = $false; code = 'duplicate_id' } | ConvertTo-Json -Compress))
        [Console]::Out.Flush()
        return
      }

      $seen[$correlationId] = $true
      [Console]::Out.WriteLine((@{ id = $correlationId; ok = $true; code = 'verified' } | ConvertTo-Json -Compress))
      [Console]::Out.Flush()

      if ($seen.Count -eq 2) { return }
    }
  }
}

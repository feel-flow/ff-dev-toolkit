$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$current = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$trusted = @($current, 'S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
$sidType = [System.Security.Principal.SecurityIdentifier]
# A request is an operation line with an optional tag, path lines and a "." line.
# Each reply line of a tagged request starts with the tag and "|", and the reply
# ends with "." and the tag. One process answers requests until end of input; a
# request closed by end of input gets its reply without the end line.
# A refused path names its untrusted owner and the first writable SID after the verdict.
function Invoke-AclRequest([string[]]$frames, [bool]$closed) {
    $header = $frames[0].Split(' ')
    if ($header.Count -gt 2) { throw 'Invalid request header' }
    $operation = $header[0]
    $tag = if ($header.Count -eq 2) { $header[1] } else { '' }
    $prefix = if ($tag.Length -gt 0) { $tag + '|' } else { '' }
    $paths = @($frames | Select-Object -Skip 1 | Where-Object { $_.Length -gt 0 })
    if ($operation -eq 'private-staging') {
        if ($paths.Count -ne 1) { throw 'One fresh staging directory required' }
        $before = Get-Acl -LiteralPath $paths[0] -ErrorAction Stop
        if ($before.GetOwner($sidType).Value -ne $current) { throw 'Foreign staging owner' }
        $private = [System.Security.AccessControl.DirectorySecurity]::new()
        $private.SetOwner([System.Security.Principal.SecurityIdentifier]::new($current))
        $private.SetAccessRuleProtection($true, $false)
        foreach ($sid in $trusted) {
            $identity = [System.Security.Principal.SecurityIdentifier]::new($sid)
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $private.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $paths[0] -AclObject $private -ErrorAction Stop
    } elseif ($operation -ne 'inspect' -and $operation -ne 'private') { throw 'Unknown metadata operation' }
    # "private" checks without changing anything: like a staging directory, no right at
    # all may be granted outside the trusted SIDs (the root of a review output directory).
    $strict = $operation -eq 'private-staging' -or $operation -eq 'private'
    $position = 0
    foreach ($literal in $paths) {
        if ($literal.Length -eq 0) { continue }
        if ($literal.Contains([string][char]13)) { throw 'Invalid path frame' }
        $item = Get-Item -LiteralPath $literal -Force -ErrorAction Stop
        if ($item.PSProvider.Name -ne 'FileSystem' -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unverified path type' }
        $acl = Get-Acl -LiteralPath $literal -ErrorAction Stop
        $raw = [System.Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(), 0)
        if ($null -eq $raw.DiscretionaryAcl) { throw 'Null DACL' }
        $owner = $acl.GetOwner($sidType).Value
        $owned = if ($owner -in $trusted) { 1 } else { 0 }
        $danger = 0
        $writer = ''
        $mask = if ($item.PSIsContainer) { [long]0x500D0152 } else { [long]0x500D0116 }
        foreach ($rule in $acl.GetAccessRules($true, $true, $sidType)) {
            if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
            if ($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
            if ($rule.IdentityReference.Value -in $trusted) { continue }
            $rights = [long]$rule.FileSystemRights
            if ($rights -lt -2147483648 -or $rights -gt 4294967295) { throw 'Invalid rights' }
            $rights = $rights -band [long]4294967295
            if (($rights -band $mask) -or ($strict -and $rights -ne 0)) {
                if ($danger -eq 0) { $writer = $rule.IdentityReference.Value }
                $danger = 1
            }
        }
        $verdict = '{0}|{1}|{2}' -f $position, $owned, $danger
        if ($owned -eq 0 -or $danger -eq 1) {
            $verdict += '|' + $(if ($owned -eq 0) { $owner } else { '' }) + '|' + $writer
        }
        [Console]::Out.WriteLine($prefix + $verdict)
        $position++
    }
    if ($closed) { [Console]::Out.WriteLine('.' + $tag) }
}
# A failed request answers "E|" and its reason instead of ending the helper, so the
# caller can name the reason and later requests keep the same process.
$request = New-Object System.Collections.Generic.List[string]
while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -ne $line -and $line -ne '.') { $request.Add($line); continue }
    if ($request.Count -gt 0) {
        try { Invoke-AclRequest $request.ToArray() ($null -ne $line) }
        catch {
            $parts = $request[0].Split(' ')
            $tag = if ($parts.Count -eq 2) { $parts[1] } else { '' }
            $prefix = if ($tag.Length -gt 0) { $tag + '|' } else { '' }
            [Console]::Out.WriteLine($prefix + 'E|' + ($_.Exception.Message -replace '[\x00-\x1f]', ' '))
            if ($null -ne $line) { [Console]::Out.WriteLine('.' + $tag) }
        }
    }
    if ($null -eq $line) { break }
    $request.Clear()
}

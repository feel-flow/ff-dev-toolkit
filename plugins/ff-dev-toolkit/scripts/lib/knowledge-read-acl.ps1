$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$current = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$trusted = @($current, 'S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
$sidType = [System.Security.Principal.SecurityIdentifier]
$frames = [Console]::In.ReadToEnd().Split([char]10)
$operation = $frames[0]
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
} elseif ($operation -ne 'inspect') { throw 'Unknown metadata operation' }
$position = 0
foreach ($literal in $paths) {
    if ($literal.Length -eq 0) { continue }
    if ($literal.Contains([string][char]13)) { throw 'Invalid path frame' }
    $item = Get-Item -LiteralPath $literal -Force -ErrorAction Stop
    if ($item.PSProvider.Name -ne 'FileSystem' -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unverified path type' }
    $acl = Get-Acl -LiteralPath $literal -ErrorAction Stop
    $raw = [System.Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(), 0)
    if ($null -eq $raw.DiscretionaryAcl) { throw 'Null DACL' }
    $owned = if ($acl.GetOwner($sidType).Value -in $trusted) { 1 } else { 0 }
    $danger = 0
    $mask = if ($item.PSIsContainer) { [long]0x500D0152 } else { [long]0x500D0116 }
    foreach ($rule in $acl.GetAccessRules($true, $true, $sidType)) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        if ($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
        if ($rule.IdentityReference.Value -in $trusted) { continue }
        $rights = [long]$rule.FileSystemRights
        if ($rights -lt -2147483648 -or $rights -gt 4294967295) { throw 'Invalid rights' }
        $rights = $rights -band [long]4294967295
        if (($rights -band $mask) -or ($operation -eq 'private-staging' -and $rights -ne 0)) { $danger = 1 }
    }
    [Console]::Out.WriteLine(('{0}|{1}|{2}' -f $position, $owned, $danger))
    $position++
}

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

/** Protected-parent boundary (ADR-078), not hostile same-UID isolation. */
export const KNOWLEDGE_READ_MAX_BYTES = 4 * 1024 * 1024;
export class KnowledgeReadError extends Error {
  constructor(public readonly code: string) {
    super(`knowledge-read: ${code}`);
    this.name = "KnowledgeReadError";
  }
}
function refuse(code: string): never { throw new KnowledgeReadError(code); }
const cleanPath = (value: string): string => {
  if (!value || [...value].some(c => c.charCodeAt(0) < 32 || c.charCodeAt(0) === 127)) refuse("invalid-path");
  return value;
};
const realPath = (value: string): string => {
  cleanPath(value);
  try { return cleanPath(fs.realpathSync(value)); } catch { return refuse("unresolvable-input"); }
};
const inside = (root: string, value: string): boolean => {
  const relative = path.relative(root, value);
  return relative === "" || (relative !== ".." && !relative.startsWith(".." + path.sep) && !path.isAbsolute(relative));
};
const identity = (s: fs.Stats): string => `${s.dev}:${s.ino}`;
const version = (s: fs.Stats): string => `${identity(s)}:${s.size}:${s.mtimeMs}:${s.ctimeMs}:${s.mode}:${s.uid}:${s.nlink}`;
const metadata = (value: string): fs.Stats => {
  try { return fs.lstatSync(value); } catch { return refuse("metadata-unavailable"); }
};

/** No raw ls metadata or source line is released in errors. */
export function inspectDarwinReadAcl(output: string): boolean {
  const lines = output.split(String.fromCharCode(10)).filter(Boolean);
  const header = lines.shift();
  if (!header || !/^[-d][-rwxstST]{9}[+@ ]/.test(header)) refuse("read-unverifiable");
  const readOnly = new Set(["list", "search", "read", "readattr", "readextattr", "readsecurity", "synchronize", "file_inherit", "directory_inherit", "limit_inherit", "only_inherit"]);
  let allow = false;
  for (const line of lines) {
    const ace = /^[ ]+[0-9]+: .+ (allow|deny) ([a-z_,]+)$/.exec(line);
    if (!ace) refuse("read-unverifiable");
    if (ace[1] === "allow") {
      allow = true;
      if (ace[2].split(",").some(right => !readOnly.has(right))) refuse("additional-write-grant");
    }
  }
  if (header[10] === "+" && lines.length === 0) refuse("read-unverifiable");
  return allow;
}

export interface KnowledgeReadOptions {
  /** Only the operator/CLI layer may populate these; never discovered links. */
  explicitRoots?: readonly string[];
  explicitFiles?: readonly string[];
}

// The shell reader uses the byte-identical .ps1 resource. Keep its parity
// checked without making the bundled MCP depend on a neighbouring source file.
export const WINDOWS_KNOWLEDGE_ACL_SOURCE = String.raw`$ErrorActionPreference = 'Stop'
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
`;

export function inspectWindowsReadAcl(output: string, count: number): void {
  if (!Number.isSafeInteger(count) || count < 1) refuse("read-unverifiable");
  const lines = output.split(String.fromCharCode(10)).map(line => line.replaceAll(String.fromCharCode(13), "")).filter(Boolean);
  if (lines.length !== count || lines.some((line, index) => line !== `${index}|1|0`)) refuse("read-unverifiable");
}

function windowsReadAcl(paths: readonly string[]): void {
  const systemRoot = process.env.SystemRoot;
  if (!systemRoot || !path.isAbsolute(systemRoot)) refuse("read-unverifiable");
  const program = path.join(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
  try {
    const output = execFileSync(program, ["-NoProfile", "-NonInteractive", "-EncodedCommand", Buffer.from(WINDOWS_KNOWLEDGE_ACL_SOURCE, "utf16le").toString("base64")], {
      input: "inspect" + String.fromCharCode(10) + paths.join(String.fromCharCode(10)) + String.fromCharCode(10),
      encoding: "utf8", stdio: ["pipe", "pipe", "pipe"], windowsHide: true, timeout: 10000, maxBuffer: 128 * 1024,
    });
    inspectWindowsReadAcl(output.charCodeAt(0) === 65279 ? output.slice(1) : output, paths.length);
  } catch { refuse("read-unverifiable"); }
}

/** Independent process context; a selected document never defines the project. */
export function knowledgeProjectRoot(): string {
  const cwd = realPath(process.cwd());
  try {
    const output = execFileSync('git', ['rev-parse', '--show-toplevel'], { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 5000, maxBuffer: 16384 });
    const root = realPath(output.replace(/\r?\n$/, ''));
    if (inside(root, cwd)) return root;
  } catch { /* Outside Git, the independently selected cwd remains the context. */ }
  return cwd;
}

/** Recognize root aliases without granting links owned by a descendant checkout. */
function projectOperand(file: string, projectRoot: string): boolean {
  let cursor = path.resolve(process.cwd(), cleanPath(file));
  for (;;) {
    if (cursor === projectRoot) return true;
    try { if (realPath(cursor) === projectRoot) return true; } catch { /* Missing operands still retain their lexical parents. */ }
    const parent = path.dirname(cursor);
    if (parent === cursor) return false;
    cursor = parent;
  }
}

/** Only literal external operator selections create grants, never in-project links. */
export function knowledgeReaderForSelection(selectedMain: string, explicitFiles: readonly string[] = [], directory = false): KnowledgeReadBoundary {
  const projectRoot = knowledgeProjectRoot();
  const absolute = path.resolve(selectedMain);
  const selected = knowledgeInputExists(absolute) ? realPath(absolute) : path.join(realPath(path.dirname(absolute)), path.basename(absolute));
  return new KnowledgeReadBoundary(projectRoot, {
    explicitRoots: projectOperand(selectedMain, projectRoot) ? [] : [directory ? selected : path.dirname(selected)],
    explicitFiles: explicitFiles.filter(file => !projectOperand(file, projectRoot)),
  });
}

/** Unlike existsSync, a dangling input is present and must later be refused. */
export function knowledgeInputExists(file: string): boolean {
  try { fs.lstatSync(file); return true; }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return false;
    return refuse('metadata-unavailable');
  }
}

/** Reuse one instance for discovery and every parse in a single operation. */
export class KnowledgeReadBoundary {
  readonly projectRoot: string;
  private readonly roots: readonly string[];
  private readonly files: ReadonlySet<string>;
  private readonly anchors: ReadonlyMap<string, string>;
  private readonly directoryAcls = new Map<string, { stamp: string; allow: boolean }>();
  private readonly accepted = new Map<string, { text: string; stamp: string }>();
  private readonly uid: number;

  constructor(projectRoot: string, options: KnowledgeReadOptions = {}) {
    if (process.platform !== "win32" && typeof process.getuid !== "function") refuse("read-unverifiable");
    this.uid = typeof process.getuid === "function" ? process.getuid() : -1;
    this.projectRoot = realPath(projectRoot);
    this.roots = Object.freeze([...new Set([this.projectRoot, ...(options.explicitRoots ?? []).map(realPath)])]);
    this.files = new Set((options.explicitFiles ?? []).map(realPath));
    const anchors = new Map<string, string>();
    for (const root of this.roots) {
      const s = metadata(root);
      if (!s.isDirectory() || s.isSymbolicLink()) refuse("invalid-root");
      this.protectedStorage(root, true);
      anchors.set(root, identity(s));
    }
    this.anchors = anchors;
  }

  private checkAnchors(): void {
    for (const [root, expected] of this.anchors) {
      const s = metadata(root);
      if (!s.isDirectory() || s.isSymbolicLink() || identity(s) !== expected) refuse("root-changed");
    }
  }

  private acl(value: string, s: fs.Stats): boolean {
    if (process.platform !== "darwin") return false;
    const stamp = version(s);
    const cached = s.isDirectory() ? this.directoryAcls.get(value) : undefined;
    if (cached?.stamp === stamp) return cached.allow;
    let output: string;
    try {
      output = execFileSync("/bin/ls", ["-ldeb", "--", value], {
        encoding: "utf8", timeout: 5000, maxBuffer: 128 * 1024,
        stdio: ["ignore", "pipe", "pipe"],
        env: { PATH: "/usr/bin:/bin", LC_ALL: "C", LANG: "C" },
      });
    } catch { return refuse("read-unverifiable"); }
    const allow = inspectDarwinReadAcl(output);
    if (s.isDirectory()) this.directoryAcls.set(value, { stamp, allow });
    return allow;
  }

  private protectedStorage(value: string, directory: boolean): void {
    let cursor = value;
    let first = true;
    let unsafe = false;
    const nativePaths: string[] = [];
    for (;;) {
      const s = metadata(cursor);
      if (s.isSymbolicLink() || (first && !directory ? !s.isFile() : !s.isDirectory())) refuse("nonregular-input");
      if (first && !directory && process.platform !== 'win32' && (s.mode & 0o444) === 0) refuse('unreadable-input');
      if (first && !directory && s.nlink !== 1) refuse("hardlinked-input");
      if (process.platform === "win32") nativePaths.push(cursor);
      else {
        if (s.uid !== 0 && s.uid !== this.uid) refuse("foreign-owner");
        const allow = this.acl(cursor, s);
        const stickyDirectory = s.isDirectory() && (s.mode & 0o1000) !== 0;
        if ((s.mode & 0o022) !== 0 && !stickyDirectory) unsafe = true;
        // An owner-only outer directory shields lower write bits. Inspect all
        // ancestors above it too; a replaceable private anchor is not private.
        if (s.isDirectory() && s.uid === this.uid && (s.mode & 0o077) === 0 && !allow) unsafe = false;
      }
      const parent = path.dirname(cursor);
      if (parent === cursor) break;
      cursor = parent;
      first = false;
    }
    if (process.platform === "win32") windowsReadAcl(nativePaths);
    if (unsafe) refuse("replaceable-storage");
  }

  /** Canonicalize for metadata only, then authorize before any source read. */
  authorize(file: string): string {
    this.checkAnchors();
    const real = realPath(file);
    if (!this.roots.some(root => inside(root, real)) && !this.files.has(real)) refuse("outside-authority");
    this.protectedStorage(real, false);
    return real;
  }

  directory(directory: string): string {
    this.checkAnchors();
    const real = realPath(directory);
    if (!this.roots.some(root => inside(root, real))) refuse("outside-authority");
    this.protectedStorage(real, true);
    return real;
  }

  read(file: string): string {
    const real = this.authorize(file);
    const cached = this.accepted.get(real);
    if (cached !== undefined) {
      if (version(metadata(real)) !== cached.stamp) refuse("input-changed");
      return cached.text;
    }
    const before = metadata(real);
    if (before.size > KNOWLEDGE_READ_MAX_BYTES) refuse("input-too-large");
    const { O_RDONLY, O_NOFOLLOW, O_NONBLOCK } = fs.constants;
    const nativeWindows = process.platform === "win32";
    if (!nativeWindows && (!Number.isInteger(O_NOFOLLOW) || O_NOFOLLOW === 0 || !Number.isInteger(O_NONBLOCK) || O_NONBLOCK === 0)) refuse("read-unverifiable");
    let fd: number | undefined;
    try {
      // On Windows the verified native ACL chain supplies the same stable
      // parent precondition as the Bash reader; POSIX-only flags are absent.
      fd = fs.openSync(real, nativeWindows ? O_RDONLY : O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
      const opened = fs.fstatSync(fd);
      if (!opened.isFile() || opened.nlink !== 1 || version(opened) !== version(before)) refuse("input-changed");
      const bytes = Buffer.alloc(KNOWLEDGE_READ_MAX_BYTES + 1);
      let length = 0;
      for (;;) {
        const n = fs.readSync(fd, bytes, length, bytes.length - length, null);
        if (n === 0) break;
        length += n;
        if (length > KNOWLEDGE_READ_MAX_BYTES) refuse("input-too-large");
      }
      const after = fs.fstatSync(fd);
      if (length !== before.size || version(after) !== version(before) || version(metadata(real)) !== version(before) || this.authorize(file) !== real) refuse("input-changed");
      const snapshot = bytes.subarray(0, length);
      if (snapshot.includes(0)) refuse("nul-input");
      const text = snapshot.toString("utf8");
      if (!Buffer.from(text, "utf8").equals(snapshot)) refuse("invalid-text");
      this.accepted.set(real, { text, stamp: version(after) });
      return text;
    } catch (error) {
      if (error instanceof KnowledgeReadError) throw error;
      return refuse("read-unverifiable");
    } finally {
      if (fd !== undefined) fs.closeSync(fd);
    }
  }
}

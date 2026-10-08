<#
    把设备模板加密成可分发文件。

    用途
    ----
    .shdevicetemplate 是标准 ZIP，任何人解压后都能看到里面的
    device.json / defaults.json，从而看出底层用的是通用渲染器。
    本脚本把它整体加密，避免接收方直接看到实现方式。

    格式
    ----
    自定义容器（.shdevicetemplate.enc）：

      offset  size  内容
        0      8    固定标识 "G6DEVENC"
        8      1    格式版本 1
        9      16   PBKDF2 盐
       25      16   AES-CBC 初始向量
       41      32   明文 SHA256
       73      4    密文长度（小端）
       77      N    AES-256-CBC 密文
       77+N    32   HMAC-SHA256（覆盖 0..77+N）

    密钥由口令经 PBKDF2-SHA256（150000 次迭代）派生，
    再经 HKDF 分离出加密密钥与认证密钥。

    用法
    ----
      # 加密（生成 .enc）
      .\Protect-Gen6DeviceTemplate.ps1 -Path 模板.shdevicetemplate -Password '口令'

      # 解密（还原为可导入的 .shdevicetemplate）
      .\Protect-Gen6DeviceTemplate.ps1 -Path 模板.shdevicetemplate.enc -Password '口令' -Decrypt
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Password,
    [switch]$Decrypt,
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$MAGIC = 'G6DEVENC'
$ITERATIONS = 150000

function Get-HkdfKey {
    param([byte[]]$Prk, [string]$Info, [int]$Length)
    $h = [System.Security.Cryptography.HMACSHA256]::new($Prk)
    try {
        $infoBytes = [Text.Encoding]::ASCII.GetBytes($Info)
        $block = @()
        $output = New-Object System.Collections.Generic.List[byte]
        $counter = 1
        while ($output.Count -lt $Length) {
            $input = @()
            $input += $block
            $input += $infoBytes
            $input += [byte]$counter
            $block = $h.ComputeHash([byte[]]$input)
            $take = [Math]::Min($block.Length, $Length - $output.Count)
            for ($i = 0; $i -lt $take; $i++) { $output.Add($block[$i]) }
            $counter++
        }
        return $output.ToArray()
    } finally { $h.Dispose() }
}

function Get-DerivedKeys {
    param([byte[]]$Salt)
    $pbkdf2 = [System.Security.Cryptography.Rfc2898DeriveBytes]::new(
        $Password, $Salt, $ITERATIONS, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        $master = $pbkdf2.GetBytes(32)
    } finally { $pbkdf2.Dispose() }

    $hmac = [System.Security.Cryptography.HMACSHA256]::new([byte[]]$Salt)
    try { $prk = $hmac.ComputeHash($master) } finally { $hmac.Dispose() }
    return [ordered]@{
        Enc = Get-HkdfKey -Prk $prk -Info 'G6DEV-enc' -Length 32
        Mac = Get-HkdfKey -Prk $prk -Info 'G6DEV-mac' -Length 32
    }
}

if (-not $Decrypt) {
    # ---------------------------------------------------------------- 加密
    if (-not (Test-Path -LiteralPath $Path)) { throw "文件不存在：$Path" }
    if (-not $OutFile) { $OutFile = "$Path.enc" }

    $plain = [IO.File]::ReadAllBytes($Path)

    $salt = New-Object byte[] 16
    $iv = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($salt)
    $rng.GetBytes($iv)
    $rng.Dispose()

    $keys = Get-DerivedKeys -Salt $salt

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $keys.Enc
    $aes.IV = $iv
    $enc = $aes.CreateEncryptor()
    $cipher = $enc.TransformFinalBlock($plain, 0, $plain.Length)
    $enc.Dispose(); $aes.Dispose()

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $plainHash = $sha.ComputeHash($plain)
    $sha.Dispose()

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([Text.Encoding]::ASCII.GetBytes($MAGIC))
    $bw.Write([byte]1)
    $bw.Write($salt)
    $bw.Write($iv)
    $bw.Write($plainHash)
    $bw.Write([uint32]$cipher.Length)
    $bw.Write($cipher)
    $bw.Flush()
    $body = $ms.ToArray()
    $bw.Dispose(); $ms.Dispose()

    $hmac = [System.Security.Cryptography.HMACSHA256]::new($keys.Mac)
    $tag = $hmac.ComputeHash($body)
    $hmac.Dispose()

    $all = New-Object byte[] ($body.Length + $tag.Length)
    [Array]::Copy($body, 0, $all, 0, $body.Length)
    [Array]::Copy($tag, 0, $all, $body.Length, $tag.Length)
    [IO.File]::WriteAllBytes($OutFile, $all)

    Write-Host ("[ok] 已加密: {0}  ({1} 字节 -> {2} 字节)" -f `
        $OutFile, $plain.Length, $all.Length) -ForegroundColor Green
    return
}

# ---------------------------------------------------------------- 解密
if (-not (Test-Path -LiteralPath $Path)) { throw "文件不存在：$Path" }
if (-not $OutFile) {
    $OutFile = if ($Path.EndsWith('.enc')) { $Path.Substring(0, $Path.Length - 4) }
               else { "$Path.dec" }
}

$data = [IO.File]::ReadAllBytes($Path)
if ($data.Length -lt 109) { throw '文件过短，不是有效的加密模板。' }

$magic = [Text.Encoding]::ASCII.GetString($data, 0, 8)
if ($magic -ne $MAGIC) { throw "文件标识不正确：$magic" }
if ($data[8] -ne 1) { throw "不支持的格式版本：$($data[8])" }

$salt = $data[9..24]
$iv = $data[25..40]
$plainHash = $data[41..72]
$cipherLen = [BitConverter]::ToUInt32($data, 73)
$bodyLen = 77 + $cipherLen

if ($data.Length -ne $bodyLen + 32) { throw '文件长度与头部声明不一致，可能已损坏。' }

$keys = Get-DerivedKeys -Salt $salt

$hmac = [System.Security.Cryptography.HMACSHA256]::new($keys.Mac)
$expect = $hmac.ComputeHash($data[0..($bodyLen - 1)])
$hmac.Dispose()
for ($i = 0; $i -lt 32; $i++) {
    if ($expect[$i] -ne $data[$bodyLen + $i]) {
        throw '认证失败：口令错误，或文件已被修改。'
    }
}

$cipher = $data[77..($bodyLen - 1)]
$aes = [System.Security.Cryptography.Aes]::Create()
$aes.KeySize = 256
$aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
$aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
$aes.Key = $keys.Enc
$aes.IV = $iv
$dec = $aes.CreateDecryptor()
$plain = $dec.TransformFinalBlock($cipher, 0, $cipher.Length)
$dec.Dispose(); $aes.Dispose()

$sha = [System.Security.Cryptography.SHA256]::Create()
$actual = $sha.ComputeHash($plain)
$sha.Dispose()
for ($i = 0; $i -lt 32; $i++) {
    if ($actual[$i] -ne $plainHash[$i]) { throw '内容校验失败：解密结果与原始文件不一致。' }
}

[IO.File]::WriteAllBytes($OutFile, $plain)
Write-Host ("[ok] 已解密: {0}  ({1} 字节)" -f $OutFile, $plain.Length) -ForegroundColor Green

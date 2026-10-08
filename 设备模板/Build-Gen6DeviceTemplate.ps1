<#
    生成 SimHub 设备模板（.shdevicetemplate）。

    目的
    ----
    把本项目打包成一个可以直接用 SimHub「从文件导入设备」载入的设备类型，
    在设备列表与页面标题显示指定名称，而不是底层的通用渲染器名称。

    格式
    ----
    .shdevicetemplate 是标准 ZIP，根目录放三个文件：

      device.json    设备类型描述：品牌、名称、继承的父类型
      defaults.json  新设备实例的默认设置
      picture.png    设备封面图

    本脚本以一份真实设备实例作为结构模板，只改写标识字段后重新打包，
    保证 Settings 结构与 SimHub 期望的完全一致。
#>
[CmdletBinding()]
param(
    # SimHub 显示名 = Brand + 空格 + Name。
    # 两者必须各写一半，任何一边重复填整个名字都会在界面上显示两遍。
    # 命名规则（对照 SimHub 内建设备反推）：
    #   Brand + Name 各写一半，CustomName / DeviceTypeName 写完整显示名。
    #   若 Brand 与 Name 都填完整名字，界面会把两者拼接，显示成两遍。
    [string]$Name = '无线协议桥',
    [string]$StandardId = 'SimHubWirelessBridge',
    [string]$Brand = 'SimHub',
    [string]$DisplayName = 'SimHub 无线协议桥',
    [string]$BaseTypeId = '298E3DE7-C46A-4B2B-8A83-E10CDB0E62CE',
    [string]$ReferenceDevice = 'D:\SimHub\DevicesDefaults\34DDD03F-3B2B-4CA2-9193-455C5D98557E.shdevice',
    [string]$Picture = '',
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not (Test-Path -LiteralPath $ReferenceDevice)) { throw "参考设备文件不存在：$ReferenceDevice" }
if (-not $Picture -or -not (Test-Path -LiteralPath $Picture)) { throw "封面图片不存在：$Picture" }
if (-not $OutFile) { throw '必须指定 -OutFile' }

$src = Get-Content -LiteralPath $ReferenceDevice -Raw -Encoding UTF8 | ConvertFrom-Json

# 新的设备实例 ID，每次生成都不同，避免与已有设备冲突
$instanceId = [Guid]::NewGuid().ToString().ToUpperInvariant()

# defaults.json：沿用参考设备的设置结构，只改身份字段
$defaults = [ordered]@{
    InstanceId               = $instanceId
    DeviceTypeID             = $BaseTypeId
    Settings                 = $src.Settings
    ExtensionSettings        = [ordered]@{}
    CustomName               = $DisplayName
    # AutomaticName 必须留空：SimHub 会把 CustomName 与 AutomaticName 拼接显示，
    # 两者都填会出现"SimHub 无线协议桥 SimHub 无线协议桥"这种重复。
    AutomaticName            = $null
    DeviceTypeName           = $DisplayName
    CustomPicture            = $null
    Enabled                  = $true
    SuspendWhenMonitorIsOff  = $false
    LastStandardDevicePreset = $null
}

# device.json：描述这个设备类型
$device = [ordered]@{
    SourceFileDate       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
    Brand                = $Brand
    DetectionDescriptor  = $null
    InheritedFrom        = $BaseTypeId
    IsDeprecated         = $false
    MaximumInstances     = 99
    MinimumSimHubVersion = '9.0.0'
    GeneratedAt          = (Get-Date).ToString('o')
    Name                 = $Name
    StandardDeviceId     = $StandardId
    TemplateVersion      = 1
}

$work = Join-Path $env:TEMP ('Gen6DeviceTemplate_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $work 'device.json'),
        ($device | ConvertTo-Json -Depth 6), $utf8)
    [IO.File]::WriteAllText((Join-Path $work 'defaults.json'),
        ($defaults | ConvertTo-Json -Depth 20), $utf8)
    Copy-Item -LiteralPath $Picture -Destination (Join-Path $work 'picture.png') -Force

    if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
    $parent = Split-Path -Parent $OutFile
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $work, $OutFile, [System.IO.Compression.CompressionLevel]::Optimal, $false)

    Write-Host ("[ok] {0}  ({1} bytes)" -f $OutFile, (Get-Item -LiteralPath $OutFile).Length) -ForegroundColor Green
    Write-Host ("     显示名      : {0}" -f $DisplayName) -ForegroundColor Gray
    Write-Host ("     基础类型 ID : {0}" -f $BaseTypeId) -ForegroundColor Gray
} finally {
    try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop } catch { }
}

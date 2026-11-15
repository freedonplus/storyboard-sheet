param(
    [Parameter(Mandatory = $true)][string]$SpecPath,
    [string]$PanelsDir = "",
    [switch]$RequirePanels
)

# storyboard-sheet 镜头单静态校验
# 不过不开图：任何 FAIL 都应先修 JSON 再进入生图。
# 退出码：0 = 全部通过（WARN 不阻塞）；1 = 存在 FAIL。

$ErrorActionPreference = "Stop"

$fail = New-Object System.Collections.ArrayList
$warn = New-Object System.Collections.ArrayList

function Add-Fail([string]$msg) { [void]$fail.Add($msg) }
function Add-Warn([string]$msg) { [void]$warn.Add($msg) }

function Get-Prop($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Test-Empty($v) {
    if ($null -eq $v) { return $true }
    if ($v -is [string]) { return [string]::IsNullOrWhiteSpace($v) }
    return $false
}

function ConvertTo-Seconds([string]$timeText) {
    # "00:00.0-00:02.2s" -> @(start, end)；失败返回 $null
    $m = [regex]::Match($timeText, '^(\d{1,2}):(\d{2}(?:\.\d+)?)-(\d{1,2}):(\d{2}(?:\.\d+)?)s$')
    if (-not $m.Success) { return $null }
    $s = [double]$m.Groups[1].Value * 60 + [double]$m.Groups[2].Value
    $e = [double]$m.Groups[3].Value * 60 + [double]$m.Groups[4].Value
    return @($s, $e)
}

if (-not (Test-Path -LiteralPath $SpecPath)) { throw "spec not found: $SpecPath" }
try {
    $spec = Get-Content -LiteralPath $SpecPath -Encoding utf8 -Raw | ConvertFrom-Json
}
catch {
    throw "spec is not valid JSON: $($_.Exception.Message)"
}

# ---------- 1. 顶层与 anchors ----------
$cols = Get-Prop $spec "cols"
$rows = Get-Prop $spec "rows"
if (Test-Empty $cols) { Add-Fail "缺少 cols" }
if (Test-Empty $rows) { Add-Fail "缺少 rows" }

$anchors = Get-Prop $spec "anchors"
$anchorKeys = @("style", "scene", "blueprint", "blocking", "axis", "lighting", "props", "negative")
if ($null -eq $anchors) {
    Add-Fail "缺少 anchors 块（单一事实源，八句锚点原句）"
}
else {
    foreach ($k in $anchorKeys) {
        if (Test-Empty (Get-Prop $anchors $k)) { Add-Fail "anchors.$k 缺失或为空" }
    }
    $chars = @(Get-Prop $anchors "characters")
    if ($chars.Count -eq 0) { Add-Fail "anchors.characters 缺失或为空数组" }
    else {
        for ($ci = 0; $ci -lt $chars.Count; $ci++) {
            if (Test-Empty $chars[$ci]) { Add-Fail "anchors.characters[$ci] 为空" }
        }
    }
}

$cameras = @(Get-Prop $spec "cameras")
$cameraIds = @{}
foreach ($c in $cameras) {
    $cid = Get-Prop $c "id"
    if (Test-Empty $cid) { Add-Fail "cameras 中存在缺 id 的机位"; continue }
    if ($cameraIds.ContainsKey([string]$cid)) { Add-Fail "机位 id 重复: $cid" }
    $cameraIds[[string]$cid] = $true
}
if ($cameras.Count -eq 0) { Add-Fail "缺少 cameras 机位表" }

# ---------- 2. shots 基础 ----------
$shots = @(Get-Prop $spec "shots")
if ($shots.Count -eq 0) { throw "shots is empty" }

if (-not (Test-Empty $cols) -and -not (Test-Empty $rows)) {
    $cap = [int]$cols * [int]$rows
    if ($shots.Count -gt $cap) { Add-Fail "shots ($($shots.Count)) 超过网格容量 ($cap)" }
    $titleCell = Get-Prop $spec "title_cell"
    if ($titleCell -eq $true -and $shots.Count -eq $cap) {
        Add-Warn "title_cell=true 但 shots 已占满 $cap 格，标题卡不会出现"
    }
    if ($titleCell -eq $true -and $shots.Count -lt ($cap - 1)) {
        Add-Warn "title_cell=true 且空格多于 1 格，空位将留深底"
    }
}

$requiredShot = @("id", "time", "name", "file", "camera", "framing", "cut_in", "cut_out", "in_state", "out_state", "prompt")
$shotIds = @{}
$prevEnd = $null
$prevOut = $null
$prevId = $null

for ($i = 0; $i -lt $shots.Count; $i++) {
    $s = $shots[$i]
    $sid = [string](Get-Prop $s "id")
    if (Test-Empty $sid) { $sid = "#$($i + 1)" }

    foreach ($k in $requiredShot) {
        if (Test-Empty (Get-Prop $s $k)) { Add-Fail "$sid 缺少字段 $k" }
    }

    # 镜头号连续
    $expect = "SH{0:d3}" -f ($i + 1)
    if ($sid -ne $expect) { Add-Fail "镜头号不连续：第 $($i + 1) 格应为 $expect，实为 $sid" }
    if ($shotIds.ContainsKey($sid)) { Add-Fail "镜头号重复: $sid" }
    $shotIds[$sid] = $i

    # 时间区间
    $range = ConvertTo-Seconds ([string](Get-Prop $s "time"))
    if ($null -eq $range) {
        Add-Fail "$sid time 格式错误（应为 00:00.0-00:02.2s）: $(Get-Prop $s 'time')"
    }
    else {
        if ($range[1] -le $range[0]) { Add-Fail "$sid time 终点不大于起点" }
        if ($null -ne $prevEnd) {
            $sceneBreak = (Get-Prop $s "scene_break") -eq $true
            if ([math]::Abs($range[0] - $prevEnd) -gt 0.001 -and -not $sceneBreak) {
                Add-Fail "$sid 时间不接：上一格终点 $prevEnd s，本格起点 $($range[0]) s（换场请标 scene_break）"
            }
        }
        $prevEnd = $range[1]
    }

    # 尾态/首态逐字接力
    $sceneBreak = (Get-Prop $s "scene_break") -eq $true
    if ($i -gt 0 -and -not $sceneBreak) {
        $inState = [string](Get-Prop $s "in_state")
        if ($inState -cne $prevOut) {
            Add-Fail "$sid in_state 与 $prevId out_state 未逐字相等（换场请标 scene_break）"
        }
    }
    $prevOut = [string](Get-Prop $s "out_state")
    $prevId = $sid

    # 机位引用
    $cam = [string](Get-Prop $s "camera")
    if (-not (Test-Empty $cam) -and $cameras.Count -gt 0 -and -not $cameraIds.ContainsKey($cam)) {
        Add-Fail "$sid 引用的机位 $cam 不在 cameras 表中"
    }

    # prompt 原句包含 anchors（高溯源硬校验）
    $prompt = [string](Get-Prop $s "prompt")
    if (-not (Test-Empty $prompt) -and $null -ne $anchors) {
        foreach ($k in $anchorKeys) {
            $av = [string](Get-Prop $anchors $k)
            if (-not (Test-Empty $av) -and -not $prompt.Contains($av)) {
                Add-Fail "$sid prompt 未原句包含 anchors.$k"
            }
        }
        # 角色锚点：shot 声明 cast（出场角色名）则只查出场者，否则全查
        $cast = @(Get-Prop $s "cast")
        foreach ($c in @(Get-Prop $anchors "characters")) {
            $ctext = [string]$c
            if (Test-Empty $ctext) { continue }
            $cname = $ctext
            $sepIdx = $ctext.IndexOf("：")
            if ($sepIdx -lt 0) { $sepIdx = $ctext.IndexOf(":") }
            if ($sepIdx -gt 0) { $cname = $ctext.Substring(0, $sepIdx) }
            if ($cast.Count -gt 0 -and ($cast -notcontains $cname)) { continue }
            if (-not $prompt.Contains($ctext)) {
                Add-Fail "$sid prompt 未原句包含角色锚点: $ctext"
            }
        }
        # 出格状态应写进 prompt；入格状态首格/换场格可省
        $outState = [string](Get-Prop $s "out_state")
        if (-not (Test-Empty $outState) -and -not $prompt.Contains($outState)) {
            Add-Fail "$sid prompt 未包含 out_state 原句"
        }
        if ($i -gt 0 -and -not $sceneBreak) {
            $inState2 = [string](Get-Prop $s "in_state")
            if (-not (Test-Empty $inState2) -and -not $prompt.Contains($inState2)) {
                Add-Fail "$sid prompt 未包含 in_state 原句"
            }
        }
    }

    # 参考图链
    $ref = Get-Prop $s "ref"
    if ($i -eq 0 -or $sceneBreak) {
        if (-not (Test-Empty $ref)) { Add-Warn "$sid 是首格/换场格，ref 应为空（断链重开），实为 $ref" }
    }
    else {
        if (Test-Empty $ref) {
            Add-Warn "$sid ref 为空但未标 scene_break，参考图链中断"
        }
        else {
            foreach ($r in ([string]$ref -split '\+')) {
                $r = $r.Trim()
                if (-not $shotIds.ContainsKey($r)) {
                    Add-Fail "$sid ref 引用了不存在或排在其后的镜头: $r"
                }
            }
        }
    }

    # 溯源字段：定稿前允许为空，给 WARN
    if (Test-Empty (Get-Prop $s "seed")) { Add-Warn "$sid seed 未回写（交付前必须填，工具不给则在 qa 注明）" }
    if (Test-Empty (Get-Prop $s "qa")) { Add-Warn "$sid qa 未回写（交付前必须填质检结论）" }

    # 帧文件
    if ($PanelsDir -ne "") {
        $f = [string](Get-Prop $s "file")
        if (-not (Test-Empty $f)) {
            $fp = Join-Path $PanelsDir $f
            if (-not (Test-Path -LiteralPath $fp)) {
                if ($RequirePanels) { Add-Fail "$sid 帧文件缺失: $fp" }
                else { Add-Warn "$sid 帧文件缺失: $fp" }
            }
        }
    }
}

# ---------- 输出 ----------
Write-Output ("validate: " + $SpecPath + "  shots=" + $shots.Count)
foreach ($w in $warn) { Write-Output ("WARN  " + $w) }
foreach ($f in $fail) { Write-Output ("FAIL  " + $f) }
Write-Output ("result: " + $fail.Count + " fail, " + $warn.Count + " warn")

if ($fail.Count -gt 0) { exit 1 }
exit 0

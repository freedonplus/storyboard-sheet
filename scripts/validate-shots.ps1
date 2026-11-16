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

# 本镜头动作段：从“本镜头：”到“出格状态：”之间，用于相邻格推进度比对
function Get-ActionText([string]$prompt) {
    $i = $prompt.IndexOf("本镜头：")
    if ($i -lt 0) { return "" }
    $j = $prompt.IndexOf("出格状态：", $i)
    if ($j -lt 0) { $j = $prompt.Length }
    $seg = $prompt.Substring($i, $j - $i)
    # 去掉共用的机位描述前缀，只比"动作本身"：取第一个分号之后
    $k = $seg.IndexOf("；")
    if ($k -ge 0 -and $k -lt $seg.Length - 1) { $seg = $seg.Substring($k + 1) }
    return $seg
}

function Get-BigramSet([string]$text) {
    $h = New-Object 'System.Collections.Generic.HashSet[string]'
    $clean = $text -replace '\s', ''
    for ($k = 0; $k -lt $clean.Length - 1; $k++) { [void]$h.Add($clean.Substring($k, 2)) }
    return $h
}

function Test-TooSimilar($setA, $setB, [double]$threshold) {
    if ($setA.Count -eq 0 -or $setB.Count -eq 0) { return $false }
    $inter = 0
    foreach ($x in $setA) { if ($setB.Contains($x)) { $inter++ } }
    $union = $setA.Count + $setB.Count - $inter
    return (([double]$inter / $union) -gt $threshold)
}

if (-not (Test-Path -LiteralPath $SpecPath)) { throw "spec not found: $SpecPath" }
try {
    $spec = Get-Content -LiteralPath $SpecPath -Encoding utf8 -Raw | ConvertFrom-Json
}
catch {
    throw "spec is not valid JSON: $($_.Exception.Message)"
}

# ---------- 1. 顶层与 anchors ----------
# 风格是可选装饰项：故事板只作参考，衔接优先。缺失时按 realistic 兜底，不阻塞。
$stylePresets = @("realistic", "line_bw", "graphite", "manga_tone", "cel2d", "guoman3d", "aaa_cg", "watercolor")
$stylePreset = [string](Get-Prop $spec "style_preset")
if (Test-Empty $stylePreset) {
    Add-Warn "未写 style_preset，按 realistic 兜底（风格不影响衔接校验）"
}
elseif ($stylePresets -notcontains $stylePreset) {
    Add-Fail "style_preset 非法值: $stylePreset（可选: $($stylePresets -join '/')）"
}

$cols = Get-Prop $spec "cols"
$rows = Get-Prop $spec "rows"
if (Test-Empty $cols) { Add-Fail "缺少 cols" }
if (Test-Empty $rows) { Add-Fail "缺少 rows" }

# 出图模式：panel = 逐格生成再拼板（质量最高，N 次生图）；single = 一次整板（1 次生图，成本最低）
$boardMode = [string](Get-Prop $spec "board_mode")
if (Test-Empty $boardMode) { $boardMode = "panel" }
if (@("panel", "single") -notcontains $boardMode) {
    Add-Fail "board_mode 只能是 panel（逐格）或 single（单次整板），实为 $boardMode"
}
$boardPrompt = [string](Get-Prop $spec "board_prompt")
if ($boardMode -eq "single") {
    if (Test-Empty $boardPrompt) {
        Add-Fail "board_mode=single 但缺少 board_prompt（整板一次生成的完整 Prompt 原句）"
    }
}

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

# 负向四段（base/anatomy/geometry/separation）：缺段视为没写负向
$negParts = Get-Prop $anchors "negative_parts"
$negKeys = @("base", "anatomy", "geometry", "separation")
if ($null -eq $negParts) {
    Add-Fail "缺少 anchors.negative_parts（负向四段：base/anatomy/geometry/separation）"
}
else {
    foreach ($nk in $negKeys) {
        if (Test-Empty (Get-Prop $negParts $nk)) { Add-Fail "anchors.negative_parts.$nk 缺失或为空" }
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
if ($boardMode -eq "single") {
    # 单次整板：没有单帧文件，也没有单格 prompt，全部信息汇总在 board_prompt
    $requiredShot = @("id", "time", "name", "camera", "framing", "cut_in", "cut_out", "in_state", "out_state")
}
$shotIds = @{}
$prevEnd = $null
$prevOut = $null
$prevId = $null
$prevSide = @{}
$prevRev = $false
$prevScene = $true
$prevFraming = ""
$prevActionSet = $null
$prevDelta = $null

for ($i = 0; $i -lt $shots.Count; $i++) {
    $s = $shots[$i]
    $sid = [string](Get-Prop $s "id")
    if (Test-Empty $sid) { $sid = "#$($i + 1)" }
    $cast = @(Get-Prop $s "cast")

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

    # ---------- 衔接推进（故事板只作参考，格与格必须真的有推进） ----------
    $framing = [string](Get-Prop $s "framing")
    $framingLevel = @{ "大远景" = 1; "远景" = 2; "全景" = 3; "中景" = 4; "中近景" = 5; "近景" = 6; "特写" = 7; "大特写" = 8 }

    # 相邻景别不连跳两级
    if (-not $sceneBreak -and $prevFraming -ne "" -and $framingLevel.ContainsKey($framing) -and $framingLevel.ContainsKey($prevFraming)) {
        $jump = [math]::Abs($framingLevel[$framing] - $framingLevel[$prevFraming])
        if ($jump -ge 3) { Add-Fail "$sid 景别连跳两级以上：$prevFraming -> $framing（中间补一格过渡景别）" }
    }

    # delta 四量表：本格对上一格到底改变了什么
    $deltaKeys = @("contact", "shift", "phase", "change")
    $deltaObj = Get-Prop $s "delta"
    if ($null -eq $deltaObj) {
        Add-Fail "$sid 缺少 delta（衔接四量表 contact/shift/phase/change）"
    }
    else {
        foreach ($dk in $deltaKeys) {
            if (Test-Empty (Get-Prop $deltaObj $dk)) { Add-Fail "$sid delta.$dk 缺失或为空" }
        }
        $contact = [string](Get-Prop $deltaObj "contact")
        $change = [string](Get-Prop $deltaObj "change")
        $outState = [string](Get-Prop $s "out_state")
        $pText = if ($boardMode -eq "single") { $boardPrompt } else { [string](Get-Prop $s "prompt") }
        if (-not (Test-Empty $pText)) {
            if (-not (Test-Empty $contact) -and -not $pText.Contains($contact)) {
                Add-Warn "$sid 接触点未在 prompt 原句出现: $contact"
            }
            # 可视结果必须落进 out_state：这一格到底改变了什么，要看得出
            if (-not (Test-Empty $change) -and -not (Test-Empty $outState) -and -not $outState.Contains($change)) {
                Add-Fail "$sid delta.change 未写进 out_state（可视结果必须落在出格状态里）: $change"
            }
        }
        # 相邻两格变化量不允许四项全同（等于没推进）
        if ($null -ne $prevDelta) {
            $same = 0
            foreach ($dk in $deltaKeys) {
                if ([string](Get-Prop $deltaObj $dk) -ceq [string](Get-Prop $prevDelta $dk)) { $same++ }
            }
            if ($same -eq $deltaKeys.Count -and -not $sceneBreak) {
                Add-Fail "$sid delta 四项与上一格完全相同（这一格没有推进）"
            }
        }
        $prevDelta = $deltaObj
    }

    # 相邻两格动作描述过像 = 换了张图但事件没动
    # 单次整板没有逐格 prompt，动作相似度在 board_prompt 里无法逐格切分，改为提示人工终审核对
    if ($boardMode -eq "panel") {
        $actionText = Get-ActionText ([string](Get-Prop $s "prompt"))
        $actionSet = Get-BigramSet $actionText
        if ($null -ne $prevActionSet -and -not $sceneBreak -and -not (Test-Empty $actionText)) {
            if (Test-TooSimilar $prevActionSet $actionSet 0.5) {
                Add-Fail "$sid 与上一格动作描述高度重复（推进不足，改写本格动作或换景别/换机位）"
            }
        }
        $prevActionSet = $actionSet
    }
    $prevFraming = $framing

    # 机位引用
    $cam = [string](Get-Prop $s "camera")
    if (-not (Test-Empty $cam) -and $cameras.Count -gt 0 -and -not $cameraIds.ContainsKey($cam)) {
        Add-Fail "$sid 引用的机位 $cam 不在 cameras 表中"
    }

    # prompt 原句包含 anchors（高溯源硬校验）；单次整板用 board_prompt 做同一套比对
    $prompt = [string](Get-Prop $s "prompt")
    if ($boardMode -eq "single") { $prompt = $boardPrompt }
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
        # 单次整板里整板 Prompt 是逐格一行，允许缩写成“该格可视结果”，因此降为 WARN
        $outState = [string](Get-Prop $s "out_state")
        if (-not (Test-Empty $outState) -and -not $prompt.Contains($outState)) {
            if ($boardMode -eq "single") {
                if (-not $prompt.Contains([string](Get-Prop $deltaObj "change"))) {
                    Add-Warn "$sid board_prompt 里找不到本格可视结果（delta.change），这一格的推进可能没写进整板 Prompt"
                }
            }
            else {
                Add-Fail "$sid prompt 未包含 out_state 原句"
            }
        }
        if ($boardMode -eq "panel" -and $i -gt 0 -and -not $sceneBreak) {
            $inState2 = [string](Get-Prop $s "in_state")
            if (-not (Test-Empty $inState2) -and -not $prompt.Contains($inState2)) {
                Add-Fail "$sid prompt 未包含 in_state 原句"
            }
        }
    }

    # 参考图链（仅逐格模式；单次整板没有格间参考链）
    $ref = Get-Prop $s "ref"
    if ($boardMode -eq "single") {
        # 单次整板不校验参考图链
    }
    elseif ($i -eq 0 -or $sceneBreak) {
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

    # ---------- 屏幕侧位锁定（防一格在左一格跑到右） ----------
    $sideObj = Get-Prop $s "screen_side"
    $sideMap = @{}
    if ($null -eq $sideObj) {
        Add-Fail "$sid 缺少 screen_side（本格可见角色在画面的 left/center/right）"
    }
    else {
        foreach ($sp in $sideObj.PSObject.Properties) {
            $sv = [string]$sp.Value
            if (@("left", "center", "right") -notcontains $sv) {
                Add-Fail "$sid screen_side.$($sp.Name) 只能是 left/center/right，实为 $sv"
            }
            $sideMap[[string]$sp.Name] = $sv
            if ($cast.Count -gt 0 -and ($cast -notcontains [string]$sp.Name)) {
                Add-Fail "$sid screen_side 里的 $($sp.Name) 不在 cast 中"
            }
        }
        if ($sideMap.Count -eq 0) { Add-Fail "$sid screen_side 为空（至少列一个可见角色）" }
    }

    $rev = (Get-Prop $s "reverse_shot") -eq $true
    if ($rev -and $prevRev) { Add-Fail "$sid 连续两格都标 reverse_shot（反打必须成对，第二格应切回原侧位）" }
    if (-not $sceneBreak -and -not $rev -and $prevSide.Count -gt 0 -and $sideMap.Count -gt 0) {
        $rank = @{ "left" = 0; "center" = 0.5; "right" = 1 }
        # 单角色跨格换边（左↔右）同样算翻转
        foreach ($nm in $sideMap.Keys) {
            $cname = [string]$nm
            if (-not $prevSide.ContainsKey($cname)) { continue }
            $a = [string]$prevSide[$cname]
            $b = [string]$sideMap[$cname]
            if ($a -ne $b -and $a -ne "center" -and $b -ne "center") {
                Add-Fail "$sid 角色 $cname 跨格换边：上格 $a、本格 $b（确需反打请标 reverse_shot）"
            }
        }
        $names = @($sideMap.Keys | Sort-Object)
        for ($x = 0; $x -lt $names.Count; $x++) {
            for ($y = $x + 1; $y -lt $names.Count; $y++) {
                $a = [string]$names[$x]; $b = [string]$names[$y]
                if (-not $prevSide.ContainsKey($a) -or -not $prevSide.ContainsKey($b)) { continue }
                $now = $rank[$sideMap[$a]] - $rank[$sideMap[$b]]
                $before = $rank[$prevSide[$a]] - $rank[$prevSide[$b]]
                if ([math]::Sign($now) -ne [math]::Sign($before)) {
                    Add-Fail "$sid 角色左右次序翻转：$a/$b 上格为 $($prevSide[$a])/$($prevSide[$b])，本格为 $($sideMap[$a])/$($sideMap[$b])（反打请标 reverse_shot）"
                }
            }
        }
    }

    if (-not (Test-Empty $prompt)) {
        $zh = @{ "left" = "左侧"; "center" = "中部"; "right" = "右侧" }
        foreach ($nm in $sideMap.Keys) {
            $phrase = "${nm}在画面$($zh[$sideMap[$nm]])"
            if (-not $prompt.Contains($phrase)) {
                if ($boardMode -eq "single") {
                    Add-Warn "$sid 整板 Prompt 未单独写出侧位句 $phrase（单次整板由轴线句统一约束，建议补一句更稳）"
                }
                else {
                    Add-Fail "$sid prompt 未含侧位句: $phrase"
                }
            }
        }
        if ($null -ne $negParts) {
            foreach ($nk in $negKeys) {
                $nv = [string](Get-Prop $negParts $nk)
                if (-not (Test-Empty $nv) -and -not $prompt.Contains($nv)) {
                    Add-Fail "$sid prompt 未原句包含 anchors.negative_parts.$nk"
                }
            }
        }
    }

    # ---------- 参考图槽位绑定（防两个主体的参考搞反） ----------
    $rbPropInfo = $s.PSObject.Properties["ref_binding"]
    if ($null -eq $rbPropInfo) {
        # 单次整板可以完全不传参考图，此时不要求逐格 ref_binding
        if ($boardMode -ne "single") {
            Add-Fail "$sid 缺少 ref_binding（首格无参考图时写空数组）"
        }
    }
    else {
        $rb = @()
        if ($null -ne $rbPropInfo.Value) { $rb = @($rbPropInfo.Value) }
        $slotSeen = @{}
        foreach ($item in $rb) {
            $slot = [string](Get-Prop $item "slot")
            $subj = [string](Get-Prop $item "subject")
            $role = [string](Get-Prop $item "role")
            if (Test-Empty $slot) { Add-Fail "$sid ref_binding 存在缺 slot 的项"; continue }
            if ($slot -notmatch '^图片\d+$') { Add-Fail "$sid ref_binding slot 应写成 图片N，实为 $slot" }
            if (Test-Empty $subj) { Add-Fail "$sid ref_binding[$slot] 缺 subject" }
            if (@("identity", "layout") -notcontains $role) { Add-Fail "$sid ref_binding[$slot] role 只能是 identity/layout，实为 $role" }
            if ($slotSeen.ContainsKey($slot)) { Add-Fail "$sid ref_binding slot 重复: $slot" }
            $slotSeen[$slot] = $subj
            if (-not (Test-Empty $prompt) -and -not $prompt.Contains($slot)) {
                Add-Fail "$sid prompt 未出现槽位 $slot 的用途句（应写“$slot 仅提供…”）"
            }
        }
        if (-not (Test-Empty $ref) -and $rb.Count -eq 0) {
            Add-Fail "$sid ref 非空但 ref_binding 为空，参考图没绑主体"
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

    $prevSide = $sideMap
    $prevRev = $rev
}

# ---------- 输出 ----------
Write-Output ("validate: " + $SpecPath + "  shots=" + $shots.Count)
foreach ($w in $warn) { Write-Output ("WARN  " + $w) }
foreach ($f in $fail) { Write-Output ("FAIL  " + $f) }
Write-Output ("result: " + $fail.Count + " fail, " + $warn.Count + " warn")

if ($fail.Count -gt 0) { exit 1 }
exit 0
